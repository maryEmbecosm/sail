(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*    Brian Campbell                                                      *)
(*    Thomas Bauereiss                                                    *)
(*    Anthony Fox                                                         *)
(*    Jon French                                                          *)
(*    Dominic Mulligan                                                    *)
(*    Stephen Kell                                                        *)
(*    Mark Wassell                                                        *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open PPrint
open Pretty_print_common

let opt_lem_output_dir = ref None
let opt_isa_output_dir = ref None
let opt_coq_output_dir = ref None

type out_type =
  | Lem_out of string list
  | Coq_out of string list

let get_lexbuf f =
  let in_chan = open_in f in
  let lexbuf = Lexing.from_channel in_chan in
  lexbuf.Lexing.lex_curr_p <- { Lexing.pos_fname = f;
                                Lexing.pos_lnum = 1;
                                Lexing.pos_bol = 0;
                                Lexing.pos_cnum = 0; };
  lexbuf, in_chan

let parse_file ?loc:(l=Parse_ast.Unknown) (f : string) : Parse_ast.defs =
  let open Reporting in
  try
    let lexbuf, in_chan = get_lexbuf f in
    begin
      try
        let ast = Parser.file Lexer.token lexbuf in
        close_in in_chan; ast
      with
      | Parser.Error ->
         let pos = Lexing.lexeme_start_p lexbuf in
         let tok = Lexing.lexeme lexbuf in
         raise (Fatal_error (Err_syntax (pos, "current token: " ^ tok)))
      | Lexer.LexError(s,p) ->
         raise (Fatal_error (Err_lex (p, s)))
    end
  with
  | Sys_error err -> raise (err_general l err)

(* Simple preprocessor features for conditional file loading *)
module StringSet = Set.Make(String)

let default_symbols =
  List.fold_left (fun set str -> StringSet.add str set) StringSet.empty
    [ "FEATURE_IMPLICITS";
      "FEATURE_CONSTANT_TYPES";
    ]

let symbols = ref default_symbols

let clear_symbols () = symbols := default_symbols

let cond_pragma l defs =
  let depth = ref 0 in
  let in_then = ref true in
  let then_defs = ref [] in
  let else_defs = ref [] in

  let push_def def =
    if !in_then then
      then_defs := (def :: !then_defs)
    else
      else_defs := (def :: !else_defs)
  in

  let rec scan = function
    | Parse_ast.DEF_pragma ("endif", _, _) :: defs when !depth = 0 ->
       (List.rev !then_defs, List.rev !else_defs, defs)
    | Parse_ast.DEF_pragma ("else", _, _) :: defs when !depth = 0 ->
       in_then := false; scan defs
    | (Parse_ast.DEF_pragma (p, _, _) as def) :: defs when p = "ifdef" || p = "ifndef" ->
       incr depth; push_def def; scan defs
    | (Parse_ast.DEF_pragma ("endif", _, _) as def) :: defs->
       decr depth; push_def def; scan defs
    | def :: defs ->
       push_def def; scan defs
    | [] -> raise (Reporting.err_general l "$ifdef or $ifndef never ended by $endif")
  in
  scan defs

(* We want to provide warnings for e.g. a mispelled pragma rather than
   just silently ignoring them, so we have a list here of all
   recognised pragmas. *)
let all_pragmas =
  List.fold_left (fun set str -> StringSet.add str set) StringSet.empty
    [ "define";
      "include";
      "ifdef";
      "ifndef";
      "else";
      "endif";
      "option";
      "optimize";
      "latex";
      "property";
      "counterexample";
      "suppress_warnings";
    ]

let rec preprocess opts = function
  | [] -> []
  | Parse_ast.DEF_pragma ("define", symbol, _) :: defs ->
     symbols := StringSet.add symbol !symbols;
     preprocess opts defs

  | (Parse_ast.DEF_pragma ("option", command, l) as opt_pragma) :: defs ->
     begin
       try
         let args = Str.split (Str.regexp " +") command in
         Arg.parse_argv ~current:(ref 0) (Array.of_list ("sail" :: args)) opts (fun _ -> ()) "";
       with
       | Arg.Bad message | Arg.Help message -> raise (Reporting.err_general l message)
     end;
     opt_pragma :: preprocess opts defs

  | Parse_ast.DEF_pragma ("ifndef", symbol, l) :: defs ->
     let then_defs, else_defs, defs = cond_pragma l defs in
     if not (StringSet.mem symbol !symbols) then
       preprocess opts (then_defs @ defs)
     else
       preprocess opts (else_defs @ defs)

  | Parse_ast.DEF_pragma ("ifdef", symbol, l) :: defs ->
     let then_defs, else_defs, defs = cond_pragma l defs in
     if StringSet.mem symbol !symbols then
       preprocess opts (then_defs @ defs)
     else
       preprocess opts (else_defs @ defs)

  | Parse_ast.DEF_pragma ("include", file, l) :: defs ->
     let len = String.length file in
     if len = 0 then
       (Reporting.warn "" l "Skipping bad $include. No file argument."; preprocess opts defs)
     else if file.[0] = '"' && file.[len - 1] = '"' then
       let relative = match l with
         | Parse_ast.Range (pos, _) -> Filename.dirname (Lexing.(pos.pos_fname))
         | _ -> failwith "Couldn't figure out relative path for $include. This really shouldn't ever happen."
       in
       let file = String.sub file 1 (len - 2) in
       let (Parse_ast.Defs include_defs) = parse_file ~loc:l (Filename.concat relative file) in
       let include_defs = preprocess opts include_defs in
       include_defs @ preprocess opts defs
     else if file.[0] = '<' && file.[len - 1] = '>' then
       let file = String.sub file 1 (len - 2) in
       let sail_dir =
         try Sys.getenv "SAIL_DIR" with
         | Not_found ->
            let share_dir = Manifest.dir in
            if Sys.file_exists share_dir then
              share_dir
            else
              (failwith ("Library directory " ^ share_dir ^ " does not exist. Make sure sail is installed or try setting environment variable SAIL_DIR so that I can find $include " ^ file))
       in
       let file = Filename.concat sail_dir ("lib/" ^ file) in
       let (Parse_ast.Defs include_defs) = parse_file ~loc:l file in
       let include_defs = preprocess opts include_defs in
       include_defs @ preprocess opts defs
     else
       let help = "Make sure the filename is surrounded by quotes or angle brackets" in
       (Reporting.warn "" l ("Skipping bad $include " ^ file ^ ". " ^ help); preprocess opts defs)

  | Parse_ast.DEF_pragma ("suppress_warnings", _, l) :: defs ->
     begin match Reporting.simp_loc l with
     | None -> () (* This shouldn't happen, but if it does just continue *)
     | Some (p, _) -> Reporting.suppress_warnings_for_file p.pos_fname
     end;
     preprocess opts defs

  | Parse_ast.DEF_pragma (p, arg, l) :: defs ->
     if not (StringSet.mem p all_pragmas) then
       Reporting.warn "" l ("Unrecognised directive: " ^ p);
     Parse_ast.DEF_pragma (p, arg, l) :: preprocess opts defs

  | (Parse_ast.DEF_default (Parse_ast.DT_aux (Parse_ast.DT_order (_, Parse_ast.ATyp_aux (atyp, _)), _)) as def) :: defs ->
     begin match atyp with
     | Parse_ast.ATyp_inc -> symbols := StringSet.add "_DEFAULT_INC" !symbols; def :: preprocess opts defs
     | Parse_ast.ATyp_dec -> symbols := StringSet.add "_DEFAULT_DEC" !symbols; def :: preprocess opts defs
     | _ -> def :: preprocess opts defs
     end

  | def :: defs -> def :: preprocess opts defs

let preprocess_ast opts (Parse_ast.Defs defs) = Parse_ast.Defs (preprocess opts defs)

let load_file_no_check opts order f = Initial_check.process_ast (preprocess_ast opts (parse_file f))

let load_file opts order env f =
  let ast = Initial_check.process_ast (preprocess_ast opts (parse_file f)) in
  Type_error.check env ast

let opt_just_check = ref false
let opt_ddump_tc_ast = ref false
let opt_ddump_rewrite_ast = ref None
let opt_dno_cast = ref false

let check_ast (env : Type_check.Env.t) (defs : unit Ast.defs) : Type_check.tannot Ast.defs * Type_check.Env.t =
  let env = if !opt_dno_cast then Type_check.Env.no_casts env else env in
  let ast, env = Type_error.check env defs in
  let () = if !opt_ddump_tc_ast then Pretty_print_sail.pp_defs stdout ast else () in
  let () = if !opt_just_check then exit 0 else () in
  (ast, env)


let open_output_with_check opt_dir file_name =
  let (temp_file_name, o) = Filename.open_temp_file "ll_temp" "" in
  let o' = Format.formatter_of_out_channel o in
  (o', (o, temp_file_name, opt_dir, file_name))

let open_output_with_check_unformatted opt_dir file_name =
  let (temp_file_name, o) = Filename.open_temp_file "ll_temp" "" in
  (o, temp_file_name, opt_dir, file_name)

let always_replace_files = ref true

let close_output_with_check (o, temp_file_name, opt_dir, file_name) =
  let _ = close_out o in
  let file_name = match opt_dir with
                  | None     -> file_name
                  | Some dir -> if Sys.file_exists dir then ()
                                else Unix.mkdir dir 0o775;
                                Filename.concat dir file_name in
  let do_replace = !always_replace_files || (not (Util.same_content_files temp_file_name file_name)) in
  let _ = if (not do_replace) then Sys.remove temp_file_name
          else Util.move_file temp_file_name file_name in
  ()

let generated_line f =
  Printf.sprintf "Generated by Sail from %s." f

let output_lem filename libs type_env defs =
  let generated_line = generated_line filename in
  (* let seq_suffix = if !Pretty_print_lem.opt_sequential then "_sequential" else "" in *)
  let types_module = (filename ^ "_types") in
  let monad_modules = ["Sail2_prompt_monad"; "Sail2_prompt"] in
  let operators_module =
    if !Pretty_print_lem.opt_mwords
    then "Sail2_operators_mwords"
    else "Sail2_operators_bitlists" in
  (* let libs = List.map (fun lib -> lib ^ seq_suffix) libs in *)
  let base_imports = [
      "Pervasives_extra";
      "Sail2_instr_kinds";
      "Sail2_values";
      "Sail2_string";
      operators_module
    ] @ monad_modules
  in
  let isa_thy_name = String.capitalize_ascii filename ^ "_lemmas" in
  let isa_lemmas =
    separate hardline [
      string ("theory " ^ isa_thy_name);
      string  "  imports";
      string  "    Sail.Sail2_values_lemmas";
      string  "    Sail.Sail2_state_lemmas";
      string ("    " ^ String.capitalize_ascii filename);
      string  "begin";
      string  "";
      State.generate_isa_lemmas !Pretty_print_lem.opt_mwords defs;
      string  "";
      string  "end"
    ] ^^ hardline
  in
  let ((ot,_,_,_) as ext_ot) =
    open_output_with_check_unformatted !opt_lem_output_dir (filename ^ "_types" ^ ".lem") in
  let ((o,_,_,_) as ext_o) =
    open_output_with_check_unformatted !opt_lem_output_dir (filename ^ ".lem") in
  (Pretty_print.pp_defs_lem
     (ot, base_imports)
     (o, base_imports @ (String.capitalize_ascii types_module :: libs))
     type_env defs generated_line);
  close_output_with_check ext_ot;
  close_output_with_check ext_o;
  let ((ol,_,_,_) as ext_ol) =
    open_output_with_check_unformatted !opt_isa_output_dir (isa_thy_name ^ ".thy") in
  print ol isa_lemmas;
  close_output_with_check ext_ol

let output_coq opt_dir filename libs defs =
  let generated_line = generated_line filename in
  let types_module = (filename ^ "_types") in
  let monad_modules = ["Sail2_prompt_monad"; "Sail2_prompt"; "Sail2_state"] in
  let operators_module = "Sail2_operators_mwords" in
  let base_imports = [
      "Sail2_instr_kinds";
      "Sail2_values";
      "Sail2_string";
      "Sail2_real";
      operators_module
    ] @ monad_modules
  in
  let ((ot,_,_,_) as ext_ot) =
    open_output_with_check_unformatted opt_dir (filename ^ "_types" ^ ".v") in
  let ((o,_,_,_) as ext_o) =
    open_output_with_check_unformatted opt_dir (filename ^ ".v") in
  (Pretty_print_coq.pp_defs_coq
     (ot, base_imports)
     (o, base_imports @ (types_module :: libs))
     defs generated_line);
  close_output_with_check ext_ot;
  close_output_with_check ext_o

let rec iterate (f : int -> unit) (n : int) : unit =
  if n = 0 then ()
  else (f n; iterate f (n - 1))

let output1 libpath out_arg filename type_env defs  =
  let f' = Filename.basename (Filename.chop_extension filename) in
  match out_arg with
  | Lem_out libs ->
     output_lem f' libs type_env defs
  | Coq_out libs ->
     output_coq !opt_coq_output_dir f' libs defs

let output libpath out_arg files =
  List.iter
    (fun (f, type_env, defs) ->
      output1 libpath out_arg f type_env defs)
    files

let rewrite_step n total (defs, env) (name, rewriter) =
  let t = Profile.start () in
  let defs, env = rewriter env defs in
  Profile.finish ("rewrite " ^ name) t;
  let _ = match !(opt_ddump_rewrite_ast) with
    | Some (f, i) ->
      begin
        let filename = f ^ "_rewrite_" ^ string_of_int i ^ "_" ^ name ^ ".sail" in
        (* output "" Lem_ast_out [filename, defs]; *)
        let ((ot,_,_,_) as ext_ot) = open_output_with_check_unformatted None filename in
        Pretty_print_sail.pp_defs ot defs;
        close_output_with_check ext_ot;
        opt_ddump_rewrite_ast := Some (f, i + 1)
      end
    | _ -> () in
  Util.progress "Rewrite " name n total;
  defs, env

let rewrite env rewriters defs =
  let total = List.length rewriters in
  try snd (List.fold_left (fun (n, defsenv) rw -> n + 1, rewrite_step n total defsenv rw) (1, (defs, env)) rewriters) with
  | Type_check.Type_error (_, l, err) ->
     raise (Reporting.err_typ l (Type_error.string_of_type_error err))

let rewrite_ast_initial env = rewrite env [("initial", fun env defs -> Rewriter.rewrite_defs defs, env)]

let rewrite_ast_target tgt env = rewrite env (Rewrites.rewrite_defs_target tgt)

let rewrite_ast_check env = rewrite env Rewrites.rewrite_defs_check
