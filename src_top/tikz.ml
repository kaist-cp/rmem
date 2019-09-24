(*===============================================================================*)
(*                                                                               *)
(*                rmem executable model                                          *)
(*                =====================                                          *)
(*                                                                               *)
(*  This file is:                                                                *)
(*                                                                               *)
(*  Copyright Shaked Flur, University of Cambridge       2017-2018               *)
(*  Copyright Jon French, University of Cambridge             2017               *)
(*  Copyright Christopher Pulte, University of Cambridge      2017               *)
(*                                                                               *)
(*  All rights reserved.                                                         *)
(*                                                                               *)
(*  It is part of the rmem tool, distributed under the 2-clause BSD licence in   *)
(*  LICENCE.txt.                                                                 *)
(*                                                                               *)
(*===============================================================================*)


open Printf

open Sail_impl_base
open Events
open Fragments
open CandidateExecution

open Globals

module StringSet = Set.Make(String)
module IoidMap = Map.Make(struct
  type t = Events.ioid
  let compare = compare
end)

(* if generated_dir is set, create files there with filename based on
the test name, otherwise create files here based on "out" *)
let basename_in_dir (name: string) : string =
  begin match !Globals.generateddir with
  | None -> "out"
  | Some dir ->
      Filename.concat dir (Filename.basename name)
  end

let add_to_map_list ioid str map =
  begin match IoidMap.find ioid map with
  | strs                -> IoidMap.add ioid (str :: strs) map
  | exception Not_found -> IoidMap.add ioid [str] map
  end

let pp_tex_header out test_info =
  fprintf out "%% auto generated by rmem\n";
  fprintf out "%% Revision: %s\n" Versions.Rmem.describe;
  fprintf out "%% Command line: %s\n" (String.concat " " @@ Array.to_list Sys.argv);
  fprintf out "%% Model: %s\n" (Model_aux.pp_model !Globals.model_params);
  fprintf out "%% Litmus hash: %s\n" (try List.assoc "Hash" test_info.Test.info with Not_found -> "???");
  fprintf out "%%\n"

let make_tikz_graph
      pp_instruction_ast
    (m:         Globals.ppmode)
    (test_info: Test.info)
    (cex:       'i CandidateExecution.cex_candidate)
    : unit
  =
  let replace (c: char) (n: string) (str: string) : string =
    let res = ref "" in
    String.iter
      (fun c' -> res := !res ^ (if c' = c then n else String.make 1 c'))
      str;
    !res
  in

  let pp_tikz_pretty_ioid ioid =
    let (tid, ioid) = ioid in
    sprintf "%d-%d" tid ioid
  in

  let pp_tikz_footprint ((addr, size): Sail_impl_base.footprint) : string =
    let (loc, offset) =
      match Pp.lookup_symbol_and_offset m.pp_symbol_table addr with
      | Some (loc, offset) when m.pp_prefer_symbolic_values -> (loc, offset)
      | _ -> (Pp.pp_byte_list m (byte_list_of_address addr), 0)
    in

    sprintf "%s+%d/%d" loc offset size
  in

  let pp_tikz_pretty_eiid m eiid : string =
    begin try List.assoc eiid m.pp_pretty_eiid_table with
    | Not_found ->
        let (ioid, eiid) = eiid in
        sprintf "%s-%d" (pp_tikz_pretty_ioid ioid) eiid
    end
    |> replace '.' "-"
  in

  let pp_tikz_write_slices_uncoloured m (w, ss) : string =
    let (addr, _) = w.w_addr in

    let (loc, offset) =
      match Pp.lookup_symbol_and_offset m.pp_symbol_table addr with
      | Some (loc, offset) when m.pp_prefer_symbolic_values -> (loc, offset)
      | _ -> (Pp.pp_byte_list m (byte_list_of_address addr), 0)
    in

    let slices = List.map (fun (i, j) -> sprintf "%d/%d" (i + offset) (j + offset)) ss in

    sprintf "{%s}{%s}" loc (String.concat "," slices)
  in

  let pp_pic ioid events : string =
    let es =
      match events with
      | e :: [] -> e
      | _ -> "\n    " ^ (String.concat ",\n    " events) ^ "\n  "
    in
    sprintf "%s/.events={%s}," ioid es
  in

  let pp_eiids ioid eiids : string =
    sprintf "%s/eiids/.initial={%s}," ioid eiids
  in

  let pp_tikz_edge label start target : string =
    sprintf "(%s) edge[/litmus/%s] (%s)" start label target
  in

  let pp_tikz_instruction_pic
      (prev_instructions: ioid list)
      (labels:          StringSet.t)
      (instance:        'i cex_instruction_instance)
      : (ioid list * StringSet.t * string option * string option)
    =
    let pp_deps pp_ioid =
      let map =
        match (prev_instructions, StringSet.elements labels) with
        | ([], _) -> IoidMap.empty
        | (_, []) -> IoidMap.empty
        | (ioid :: _, labels) -> IoidMap.singleton ioid labels
      in
      let map =
        Pset.elements instance.cex_address_dependencies
        |> List.filter (fun ioid -> List.mem ioid prev_instructions)
        |> List.fold_left (fun map ioid -> add_to_map_list ioid "addr" map) map
      in
      let map =
        Pset.elements instance.cex_data_dependencies
        |> List.filter (fun ioid -> List.mem ioid prev_instructions)
        |> List.fold_left (fun map ioid -> add_to_map_list ioid "data" map) map
      in
      let map =
        Pset.elements instance.cex_control_dependencies
        |> List.filter (fun ioid -> List.mem ioid prev_instructions)
        |> List.fold_left (fun map ioid -> add_to_map_list ioid "ctrl" map) map
      in

      begin match prev_instructions with
      | ioid :: _ ->
          if IoidMap.mem ioid map then map
          else IoidMap.add ioid ["po"] map
      | [] -> map
      end
      |> IoidMap.bindings
      |> List.map
          (fun (ioid, bys) ->
            List.map
              (fun by -> pp_tikz_edge by (pp_tikz_pretty_ioid ioid) pp_ioid)
              bys)
      |> List.concat
      |> String.concat "\n          "
      |> fun s -> if s = "" then None else Some s
    in

    begin match instance.cex_instruction_kind with
    | IK_barrier barrier_kind ->
        let label =
          match barrier_kind with
          (* Power barriers *)
          | Barrier_Sync      -> "sync"
          | Barrier_LwSync    -> "lwsync"
          | Barrier_Eieio     -> "eieio"
          | Barrier_Isync     -> "isync"
          (* AArch64 barriers *)
          | Barrier_DMB (d,t) ->
            let d = match d with
              | A64_FullShare  -> if t = A64_barrier_all then "sy" else ""
              | A64_InnerShare -> "ish"
              | A64_OuterShare -> "osh"
              | A64_NonShare   -> "nsh"
            in
            let t = match t with
              | A64_barrier_all -> ""
              | A64_barrier_LD  -> "ld"
              | A64_barrier_ST  -> "st"
            in
            "dmb " ^ d ^ t
          | Barrier_DSB (d,t) ->
            let d = match d with
              | A64_FullShare  -> if t = A64_barrier_all then "sy" else ""
              | A64_InnerShare -> "ish"
              | A64_OuterShare -> "osh"
              | A64_NonShare   -> "nsh"
            in
            let t = match t with
              | A64_barrier_all -> ""
              | A64_barrier_LD  -> "ld"
              | A64_barrier_ST  -> "st"
            in
            "dsb " ^ d ^ t
          | Barrier_ISB       -> "isb"
          | Barrier_TM_COMMIT -> failwith "Barrier_TM_COMMIT is not really a barrier"
          (* MIPS barriers *)
          | Barrier_MIPS_SYNC -> "sync"
          (* RISC-V barriers *)
          | Barrier_RISCV_rw_rw -> "fence rw rw"
          | Barrier_RISCV_r_rw  -> "fence r rw"
          | Barrier_RISCV_w_rw  -> "fence w rw"
          | Barrier_RISCV_rw_r  -> "fence rw r"
          | Barrier_RISCV_r_r   -> "fence r r"
          | Barrier_RISCV_w_r   -> "fence w r"
          | Barrier_RISCV_rw_w  -> "fence rw w"
          | Barrier_RISCV_r_w   -> "fence r w"
          | Barrier_RISCV_w_w   -> "fence w w"
          | Barrier_RISCV_tso   -> "fence.tso"
          | Barrier_RISCV_i     -> "fence.i"
          | Barrier_x86_MFENCE  -> "MFENCE"
        in

        let pic =
          if instance.cex_committed_barriers = [] then
            None
          else
            let ioid = pp_tikz_pretty_ioid instance.cex_instance_ioid in

            let eiids =
              List.map
                (fun b -> pp_tikz_pretty_eiid m b.beiid)
                instance.cex_committed_barriers
              |> String.concat ","
            in

            Some (pp_eiids ioid eiids)
        in

        (prev_instructions,
          StringSet.add label labels,
          pic,
          None)

    | IK_mem_read read_kind ->
        begin match instance.cex_satisfied_reads with
        | [] -> failwith "load instruction without reads (tikz)"
        | rs ->
            let ioid = pp_tikz_pretty_ioid instance.cex_instance_ioid in

            let events =
              List.map
                (fun (r, mrs) ->
                  sprintf "%s/.mem read={%s %s=%s}"
                      (pp_tikz_pretty_eiid m r.reiid)
                      (Pp.pp_brief_read_kind m r.r_read_kind)
                      (pp_tikz_footprint r.r_addr)
                      (Pp.pp_memory_value m r.r_ioid mrs.mrs_value))
                rs
            in

            (instance.cex_instance_ioid :: prev_instructions,
              StringSet.empty,
              Some (pp_pic ioid events),
              pp_deps ioid)
        end

    | IK_mem_write write_kind ->
        begin match instance.cex_propagated_writes with
        | [] -> failwith "store instruction without writes (tikz)"
        | ws ->
            let ioid = pp_tikz_pretty_ioid instance.cex_instance_ioid in

            let events =
              List.map
                (fun w ->
                    sprintf "%s/.mem write={%s %s=%s}"
                      (pp_tikz_pretty_eiid m w.weiid)
                      (Pp.pp_brief_write_kind m w.w_write_kind)
                      (pp_tikz_footprint w.w_addr)
                      (Pp.pp_write_value m w))
                ws
            in

            (instance.cex_instance_ioid :: prev_instructions,
              StringSet.empty,
              Some (pp_pic ioid events),
              pp_deps ioid)
        end

    | IK_mem_rmw (read_kind, write_kind) ->
        let ioid = pp_tikz_pretty_ioid instance.cex_instance_ioid in

        let read_events =
          begin match instance.cex_satisfied_reads with
          | [] -> failwith "load instruction without reads (tikz)"
          | rs ->
              List.map
                (fun (r, mrs) ->
                  sprintf "%s/.mem read={%s %s=%s}"
                      (pp_tikz_pretty_eiid m r.reiid)
                      (Pp.pp_brief_read_kind m r.r_read_kind)
                      (pp_tikz_footprint r.r_addr)
                      (Pp.pp_memory_value m r.r_ioid mrs.mrs_value))
                rs
          end
        in

        let write_events =
          begin match instance.cex_propagated_writes with
          | [] -> failwith "store instruction without writes (tikz)"
          | ws ->
              List.map
                (fun w ->
                    sprintf "%s/.mem write={%s %s=%s}"
                      (pp_tikz_pretty_eiid m w.weiid)
                      (Pp.pp_brief_write_kind m w.w_write_kind)
                      (pp_tikz_footprint w.w_addr)
                      (Pp.pp_write_value m w))
                ws
          end
        in

        (instance.cex_instance_ioid :: prev_instructions,
            StringSet.empty,
            Some (pp_pic ioid (read_events @ write_events)),
            pp_deps ioid)


    | IK_branch
    | IK_trans _ (* TODO: TM *)
    | IK_simple
    | IK_cache_op _(* TODO: DC/IC *)
        -> (prev_instructions, labels, None, None)
    end
  in

  let rec instructions_path_from_tree
            acc 
          : 'i CandidateExecution.cex_instruction_tree ->
            ('i CandidateExecution.cex_instruction_instance) list
    = function
    | CEX_T []             -> List.rev acc
    | CEX_T [(inst, tree)] -> instructions_path_from_tree (inst :: acc) tree
    | _ -> failwith "multiple branches are not supported by tikz"
  in

  let pp_tikz_thread_pics (tid, state) : string =
    let (_, _, pics, deps) =
      List.fold_left
        (fun (prev_instructions, labels, pics, deps) inst ->
          match pp_tikz_instruction_pic prev_instructions labels inst with
          | (prev_instructions, labels, None, None) ->
              (prev_instructions, labels, pics, deps)
          | (prev_instructions, labels, Some pic, None) ->
              (prev_instructions, labels, pic :: pics, deps)
          | (prev_instructions, labels, None, Some dep) ->
              (prev_instructions, labels, pics, dep :: deps)
          | (prev_instructions, labels, Some pic, Some dep) ->
              (prev_instructions, labels, pic :: pics, dep :: deps)
        )
        ([], StringSet.empty, [], [])
        (instructions_path_from_tree [] state.cex_instruction_tree)
    in

    let insts =
      instructions_path_from_tree [] state.cex_instruction_tree
      |> List.map (fun inst ->
          let pp_instruction =
            pp_instruction_ast m m.pp_symbol_table inst.cex_instruction inst.cex_program_loc
            (* escape some characters; see the documentation of the
            LaTeX listings package (6.1 Listins inside arguments) *
            |> replace '\\' "\\\\"
            |> replace '{' "\\{"
            |> replace '}' "\\}"
            |> replace '%' "\\%"
            *)
          in

          let assem =
            sprintf "\\node[/litmus/assem={%s}] {\\assem|%s|}; \\litmusendinst"
              (pp_tikz_pretty_ioid inst.cex_instance_ioid)
              pp_instruction
          in

          begin match Pp.lookup_symbol m.pp_symbol_table inst.cex_program_loc with
          | None -> [assem]
          | Some label ->
            [ sprintf "\\node[/litmus/assem label={%s}]; \\litmusendinst" label;
              assem
            ]
          end)
      |> List.concat
      |> String.concat "\n    "
    in

    (sprintf  "\\begin{scope}[/litmus/thread=%d,\n" tid) ^
    (sprintf  "  %s\n" (String.concat "\n  " (List.rev pics))) ^
              "]\n" ^
    (sprintf  "  \\node[/litmus/instructions] (instructions %d) {\n" tid) ^
    (*(sprintf  "    %s\n" insts) ^
              "    \\\\ % instructions must always end with this\n" ^*)
    (sprintf  "    %s\n" insts) ^
              "  };\n\n" ^
    (sprintf  "  %% Thread %d dependencies:\n" tid) ^
              "  \\begin{scope}[/litmus/instruction relations]\n" ^
    (sprintf  "    \\path %s;\n" (String.concat "\n          " (List.rev deps))) ^
              "  \\end{scope}\n" ^
              "\\end{scope}"
  in

  let nodes =
    List.map pp_tikz_thread_pics (Pmap.bindings_list cex.cex_threads)
    |> String.concat "\n\n"
  in

  let co =
    let co =
      (* remove initial writes *)
      List.filter
        (fun (w, w') -> w.w_thread <> Test.init_thread)
        (Pset.elements cex.cex_co)
    in
    match co with
    | [] -> ""
    | co ->
      let edges =
        List.map
          (fun (w, w') ->
              pp_tikz_edge "co"
                (pp_tikz_pretty_eiid m w.weiid)
                (pp_tikz_pretty_eiid m w'.weiid))
          co
      in
                "  % coherence\n" ^
      (sprintf  "  \\path %s;" (String.concat "\n        " edges))
  in

  let rf =
    match Pset.elements cex.cex_rf with
    | [] -> ""
    | rf ->
      let edges =
        List.map
          (fun ((w, ss), r) -> (* TODO: slices *)
              if List.mem w cex.cex_initial_writes then
                let pp_eiid = pp_tikz_pretty_eiid m r.reiid in
                sprintf "node[/litmus/init=%s] {} edge[/litmus/rf'=%s] (%s)"
                  pp_eiid
                  (pp_tikz_write_slices_uncoloured m (w, ss))
                  pp_eiid
              else
                pp_tikz_edge ("rf'=" ^ pp_tikz_write_slices_uncoloured m (w, ss))
                  (pp_tikz_pretty_eiid m w.weiid)
                  (pp_tikz_pretty_eiid m r.reiid)
          )
          rf
      in
                "  % read-from:\n" ^
      (sprintf  "  \\path %s;" (String.concat "\n        " edges))
  in

  let fr =
    match Pset.elements cex.cex_fr with
    | [] -> ""
    | fr ->
      let edges =
        List.map
          (fun (r, (w, ss)) ->
              pp_tikz_edge ("fr'=" ^ pp_tikz_write_slices_uncoloured m (w, ss))
                  (pp_tikz_pretty_eiid m r.reiid)
                  (pp_tikz_pretty_eiid m w.weiid))
          fr
      in
                "  % from-read:\n" ^
      (sprintf  "  \\path %s;" (String.concat "\n        " edges))
  in

  let tikz_out = open_out ((basename_in_dir test_info.Test.name) ^ ".tikz") in

  pp_tex_header tikz_out test_info;

  fprintf tikz_out "%s\n\n" nodes;
  fprintf tikz_out "\\begin{scope}[/litmus/event relations]\n";
  fprintf tikz_out "%s\n"
    (List.filter (fun s -> s <> "") [co; rf; fr] |> String.concat "\n\n");
  fprintf tikz_out "\\end{scope}\n";

  close_out tikz_out

module TidMap = Map.Make(struct
  type t = Events.thread_id
  let compare t1 t2 = Pervasives.compare t1 t2
end)

let make_init_state (info: Test.info) (test: 'i Test.test) : unit =
  let init_state =
    let big_num_to_int64 i : Int64.t =
      if Nat_big_num.greater i (Nat_big_num.of_int64 Int64.max_int) then
        Nat_big_num.to_int64 (Nat_big_num.sub i (Nat_big_num.pow_int_positive 2 64))
      else
        Nat_big_num.to_int64 i
    in

    let regs =
      List.fold_left
        (fun acc ((thread_id, reg_base_name), register_value) ->
            let v =
              match Sail_impl_base.integer_of_register_value register_value with
              | Some i -> big_num_to_int64 i
              | None -> failwith "bad register_value"
            in
            match TidMap.find thread_id acc with
            | regs -> TidMap.add thread_id ((reg_base_name, v) :: regs) acc
            | exception Not_found -> TidMap.add thread_id [(reg_base_name, v)] acc
        )
        (TidMap.empty: ((Sail_impl_base.reg_base_name * int64) list) TidMap.t)
        test.Test.init_reg_state

      |> TidMap.bindings
    in

    let mem =
      let mem_addr_map = Test.LocationMap.bindings test.Test.mem_addr_map in

      List.map
        (fun (address, memory_value) ->
            let int64_addr = Nat_big_num.to_int64 (Sail_impl_base.integer_of_address address) in
            let big_value =
              match Sail_impl_base.integer_of_memory_value (Globals.get_endianness ()) memory_value with
              | Some bi -> bi
              | None -> failwith "bad memory_value"
            in
            let size =
              match
                List.find (fun (_, (addr, _)) -> Sail_impl_base.addressEqual addr address) mem_addr_map
              with
              | (_, (_, size)) -> size
              | exception Not_found -> failwith "missing address"
            in
            ((int64_addr, size), big_value)
        )
        test.Test.init_mem_state
    in

    let symtab =
      List.map
        (fun ((a,sz),s) ->
          (Nat_big_num.to_int64 (Sail_impl_base.integer_of_address a), s))
        info.Test.symbol_table
    in

    Test.C.pp_state symtab (regs, mem)
  in

  let model_name =
    let params = !Globals.model_params in
    try List.assoc (params.ss.ss_model, params.t.thread_model) Model_aux.model_assoc with
    | Not_found -> failwith "Unknown combination of storage and thread sub-systems"
  in

  let states_out = open_out ((basename_in_dir info.Test.name) ^ ".states.tex") in

  pp_tex_header states_out info;

  fprintf states_out "\\newcommand{\\litmusname}{%s}%%\n" info.Test.name;
  fprintf states_out "\\newcommand{\\litmusarch}{%s}%%\n" (Archs.pp test.Test.arch);
  fprintf states_out "\\newcommand{\\rmemmodel}{%s}%%\n" model_name;
  fprintf states_out "\\newcommand{\\initstate}{%s}%%\n" init_state;

  close_out states_out

let make_final_state (test_info: Test.info) (state: string) : unit =
  let states_out = open_out_gen [Open_creat; Open_append] 0o660 (*rw,rw,r*) ((basename_in_dir test_info.Test.name) ^ ".states.tex") in
  fprintf states_out "\\newcommand{\\finalstate}{%s}%%\n" state;
  close_out states_out

module Make (ConcModel: Concurrency_model.S) :
  (GraphBackend.S with type ui_trans = ConcModel.ui_trans
                  and type instruction_ast = ConcModel.instruction_ast)= struct
(** implements GraphBackend.S with type ui_trans = ConcModel.ui_trans *)

type ui_trans = ConcModel.ui_trans
type instruction_ast = ConcModel.instruction_ast

let make_graph m test_info cex (nc: ui_trans list) =
  let m = { m with pp_kind=Ascii;
                    pp_colours=false;
                    pp_trans_prefix=false } in

  make_tikz_graph ConcModel.pp_instruction_ast m test_info cex;

  (* hack to terminate after finding the first "final" graph *)
  begin match !Globals.run_dot with
  | Some RD_final
  | Some RD_final_ok
  | Some RD_final_not_ok
      -> exit 0
  | None
  | Some RD_step
      -> ()
  end
(** end GraphBackend.S *)

end (* Make *)
