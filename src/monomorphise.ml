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

(* Could fix list:
   - Can probably trigger non-termination in the analysis or constant
     propagation with carefully constructed recursive (or mutually
     recursive) functions
*)

open Parse_ast
open Ast
open Ast_util
module Big_int = Nat_big_num
open Type_check

let size_set_limit = 64

let optmap v f =
  match v with
  | None -> None
  | Some v -> Some (f v)

let kbindings_from_list = List.fold_left (fun s (v,i) -> KBindings.add v i s) KBindings.empty
let bindings_from_list = List.fold_left (fun s (v,i) -> Bindings.add v i s) Bindings.empty
(* union was introduced in 4.03.0, a bit too recently *)
let bindings_union s1 s2 =
  Bindings.merge (fun _ x y -> match x,y with
  |  _, (Some x) -> Some x
  |  (Some x), _ -> Some x
  |  _,  _ -> None) s1 s2
let kbindings_union s1 s2 =
  KBindings.merge (fun _ x y -> match x,y with
  |  _, (Some x) -> Some x
  |  (Some x), _ -> Some x
  |  _,  _ -> None) s1 s2

let make_vector_lit sz i =
  let f j = if Big_int.equal (Big_int.modulus (Big_int.shift_right i (sz-j-1)) (Big_int.of_int 2)) Big_int.zero then '0' else '1' in
  let s = String.init sz f in
  L_aux (L_bin s,Generated Unknown)

let tabulate f n =
  let rec aux acc n =
    let acc' = f n::acc in
    if Big_int.equal n Big_int.zero then acc' else aux acc' (Big_int.sub n (Big_int.of_int 1))
  in if Big_int.equal n Big_int.zero then [] else aux [] (Big_int.sub n (Big_int.of_int 1))

let make_vectors sz =
  tabulate (make_vector_lit sz) (Big_int.shift_left (Big_int.of_int 1) sz)

let rec cross = function
  | [] -> failwith "cross"
  | [(x,l)] -> List.map (fun y -> [(x,y)]) l
  | (x,l)::t -> 
     let t' = cross t in
     List.concat (List.map (fun y -> List.map (fun l' -> (x,y)::l') t') l)

let rec cross' = function
  | [] -> [[]]
  | (h::t) ->
     let t' = cross' t in
     List.concat (List.map (fun x -> List.map (fun l ->  x::l) t') h)

let rec cross'' = function
  | [] -> [[]]
  | (k,None)::t -> List.map (fun l -> (k,None)::l) (cross'' t)
  | (k,Some h)::t ->
     let t' = cross'' t in
     List.concat (List.map (fun x -> List.map (fun l -> (k,Some x)::l) t') h)

let kidset_bigunion = function
  | [] -> KidSet.empty
  | h::t -> List.fold_left KidSet.union h t

(* TODO: deal with non-set constraints, intersections, etc somehow *)
let extract_set_nc env l var nc =
  let vars = Spec_analysis.equal_kids_ncs var [nc] in
  let rec aux_or (NC_aux (nc,l)) =
    match nc with
    | NC_equal (Nexp_aux (Nexp_var id,_), Nexp_aux (Nexp_constant n,_))
        when KidSet.mem id vars ->
       Some [n]
    | NC_or (nc1,nc2) ->
       (match aux_or nc1, aux_or nc2 with
       | Some l1, Some l2 -> Some (l1 @ l2)
       | _, _ -> None)
    | _ -> None
  in
  (* Lazily expand constraints to keep close to the original form *)
  let rec aux expanded (NC_aux (nc,l) as nc_full) =
    let re nc = NC_aux (nc,l) in
    match nc with
    | NC_set (id,is) when KidSet.mem id vars -> Some (is,re NC_true)
    | NC_and (nc1,nc2) ->
       (match aux expanded nc1, aux expanded nc2 with
       | None, None -> None
       | None, Some (is,nc2') -> Some (is, re (NC_and (nc1,nc2')))
       | Some (is,nc1'), None -> Some (is, re (NC_and (nc1',nc2)))
       | Some _, Some _ ->
          raise (Reporting.err_general l ("Multiple set constraints for " ^ string_of_kid var)))
    | NC_or _ ->
       (match aux_or nc_full with
       | Some is -> Some (is, re NC_true)
       | None -> None)
    | _ -> if expanded then None else aux true (Env.expand_constraint_synonyms env nc_full)
  in match aux false nc with
  | Some is -> is
  | None ->
     raise (Reporting.err_general l ("No set constraint for " ^ string_of_kid var ^
                                              " in " ^ string_of_n_constraint nc))

let rec peel = function
  | [], l -> ([], l)
  | h1::t1, h2::t2 -> let (l1,l2) = peel (t1, t2) in ((h1,h2)::l1,l2)
  | _,_ -> assert false

let rec split_insts = function
  | [] -> [],[]
  | (k,None)::t -> let l1,l2 = split_insts t in l1,k::l2
  | (k,Some v)::t -> let l1,l2 = split_insts t in (k,v)::l1,l2

let apply_kid_insts kid_insts nc t =
  let kid_insts, kids' = split_insts kid_insts in
  let kid_insts = List.map
    (fun (v,i) -> (kopt_kid v,Nexp_aux (Nexp_constant i,Generated Unknown)))
    kid_insts in
  let subst = kbindings_from_list kid_insts in
  kids', subst_kids_nc subst nc, subst_kids_typ subst t

let rec inst_src_type insts (Typ_aux (ty,l) as typ) =
  match ty with
  | Typ_id _
  | Typ_var _
    -> insts,typ
  | Typ_fn _ ->
     raise (Reporting.err_general l "Function type in constructor")
  | Typ_bidir _ ->
     raise (Reporting.err_general l "Mapping type in constructor")
  | Typ_tup ts ->
     let insts,ts = 
       List.fold_right
         (fun typ (insts,ts) -> let insts,typ = inst_src_type insts typ in insts,typ::ts)
         ts (insts,[])
     in insts, Typ_aux (Typ_tup ts,l)
  | Typ_app (id,args) ->
     let insts,ts = 
       List.fold_right
         (fun arg (insts,args) -> let insts,arg = inst_src_typ_arg insts arg in insts,arg::args)
         args (insts,[])
     in insts, Typ_aux (Typ_app (id,ts),l)
  | Typ_exist (kopts, nc, t) -> begin
     let kid_insts, insts' = peel (kopts,insts) in
     let kopts', nc', t' = apply_kid_insts kid_insts nc t in
     match kopts' with
     | [] -> insts', t'
     | _ -> insts', Typ_aux (Typ_exist (kopts', nc', t'), l)
    end
  | Typ_internal_unknown -> Reporting.unreachable l __POS__ "escaped Typ_internal_unknown"
and inst_src_typ_arg insts (A_aux (ta,l) as tyarg) =
  match ta with
  | A_nexp _
  | A_order _
  | A_bool _
      -> insts, tyarg
  | A_typ typ ->
     let insts', typ' = inst_src_type insts typ in
     insts', A_aux (A_typ typ',l)

let rec contains_exist (Typ_aux (ty,l)) =
  match ty with
  | Typ_id _
  | Typ_var _
    -> false
  | Typ_fn (t1,t2,_) -> List.exists contains_exist t1 || contains_exist t2
  | Typ_bidir (t1, t2) -> contains_exist t1 || contains_exist t2
  | Typ_tup ts -> List.exists contains_exist ts
  | Typ_app (_,args) -> List.exists contains_exist_arg args
  | Typ_exist _ -> true
  | Typ_internal_unknown -> Reporting.unreachable l __POS__ "escaped Typ_internal_unknown"
and contains_exist_arg (A_aux (arg,_)) =
  match arg with
  | A_nexp _
  | A_order _
  | A_bool _
      -> false
  | A_typ typ -> contains_exist typ

let rec size_nvars_nexp (Nexp_aux (ne,_)) =
  match ne with
  | Nexp_var v -> [v]
  | Nexp_id _
  | Nexp_constant _
    -> []
  | Nexp_times (n1,n2)
  | Nexp_sum (n1,n2)
  | Nexp_minus (n1,n2)
    -> size_nvars_nexp n1 @ size_nvars_nexp n2
  | Nexp_exp n
  | Nexp_neg n
    -> size_nvars_nexp n
  | Nexp_app (_,args) -> List.concat (List.map size_nvars_nexp args)

(* Given a type for a constructor, work out which refinements we ought to produce *)
(* TODO collision avoidance *)
let split_src_type all_errors env id ty (TypQ_aux (q,ql)) =
  let cannot l msg default =
    let open Reporting in
    let error = Err_general (l, msg) in
    match all_errors with
    | None -> raise (Fatal_error error)
    | Some flag -> begin
        flag := false;
        print_error error;
        default
      end
  in
  let i = string_of_id id in
  (* This was originally written for the general case, but I cut it down to the
     more manageable prenex-form below *)
  let rec size_nvars_ty typ =
    let Typ_aux (ty,l) = Env.expand_synonyms env typ in
    match ty with
    | Typ_id _
    | Typ_var _
      -> (KidSet.empty,[[],typ])
    | Typ_fn _ ->
       cannot l ("Function type in constructor " ^ i) (KidSet.empty,[[],typ])
    | Typ_bidir _ ->
       cannot l ("Mapping type in constructor " ^ i) (KidSet.empty,[[],typ])
    | Typ_tup ts ->
       let (vars,tys) = List.split (List.map size_nvars_ty ts) in
       let insttys = List.map (fun x -> let (insts,tys) = List.split x in
                                        List.concat insts, Typ_aux (Typ_tup tys,l)) (cross' tys) in
       (kidset_bigunion vars, insttys)
    | Typ_app (Id_aux (Id "vector",_),
               [A_aux (A_nexp sz,_);
                _;A_aux (A_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_)]) ->
       (KidSet.of_list (size_nvars_nexp sz), [[],typ])
    | Typ_app (_, tas) ->
       (KidSet.empty,[[],typ])  (* We only support sizes for bitvectors mentioned explicitly, not any buried
                      inside another type *)
    | Typ_exist (kopts, nc, t) ->
       let (vars,tys) = size_nvars_ty t in
       let find_insts k (insts,nc) =
         let inst,nc' =
           if KidSet.mem (kopt_kid k) vars then
             let is,nc' = extract_set_nc env l (kopt_kid k) nc in
             Some is,nc'
           else None,nc
         in (k,inst)::insts,nc'
       in
       let (insts,nc') = List.fold_right find_insts kopts ([],nc) in
       let insts = cross'' insts in
       let ty_and_inst (inst0,ty) inst =
         let kopts, nc', ty = apply_kid_insts inst nc' ty in
         let ty =
           (* Typ_exist is not allowed an empty list of kids *)
           match kopts with
           | [] -> ty
           | _ -> Typ_aux (Typ_exist (kopts, nc', ty),l)
         in inst@inst0, ty
       in
       let tys = List.concat (List.map (fun instty -> List.map (ty_and_inst instty) insts) tys) in
       let free = List.fold_left (fun vars k -> KidSet.remove (kopt_kid k) vars) vars kopts in
       (free,tys)
    | Typ_internal_unknown -> Reporting.unreachable l __POS__ "escaped Typ_internal_unknown"
  in
  let size_nvars_ty (Typ_aux (ty,l) as typ) =
    match ty with
    | Typ_exist (kids,_,t) ->
       begin
         match snd (size_nvars_ty typ) with
         | [] -> []
         | [[],_] -> []
         | tys ->
            if contains_exist t then
              cannot l "Only prenex types in unions are supported by monomorphisation" []
            else tys
       end
    | _ -> []
  in
  (* TODO: reject universally quantification or monomorphise it *)
  let variants = size_nvars_ty ty in
  match variants with
  | [] -> None
  | [l,_] when List.for_all (function (_,None) -> true | _ -> false) l -> None
  | sample::_ ->
     if List.length variants > size_set_limit then
       cannot ql
         (string_of_int (List.length variants) ^ "variants for constructor " ^ i ^
            "bigger than limit " ^ string_of_int size_set_limit) None
     else
     let wrap = match id with
       | Id_aux (Id i,l) -> (fun f -> Id_aux (Id (f i),Generated l))
       | Id_aux (Operator i,l) -> (fun f -> Id_aux (Operator (f i),l))
     in
     let name_seg = function
       | (_,None) -> ""
       | (k,Some i) -> "#" ^ string_of_kid (kopt_kid k) ^ Big_int.to_string i
     in
     let name l i = String.concat "" (i::(List.map name_seg l)) in
     Some (List.map (fun (l,ty) -> (l, wrap (name l),ty)) variants)

let reduce_nexp subst ne =
  let rec eval (Nexp_aux (ne,_) as nexp) =
    match ne with
    | Nexp_constant i -> i
    | Nexp_sum (n1,n2) -> Big_int.add (eval n1) (eval n2)
    | Nexp_minus (n1,n2) -> Big_int.sub (eval n1) (eval n2)
    | Nexp_times (n1,n2) -> Big_int.mul (eval n1) (eval n2)
    | Nexp_exp n -> Big_int.shift_left (eval n) 1
    | Nexp_neg n -> Big_int.negate (eval n)
    | _ ->
       raise (Reporting.err_general Unknown ("Couldn't turn nexp " ^
                                                      string_of_nexp nexp ^ " into concrete value"))
  in eval ne


let typ_of_args args =
  match args with
  | [(E_aux (E_tuple args, (_, tannot)) as exp)] ->
     begin match destruct_tannot tannot with
     | Some (_,Typ_aux (Typ_exist _,_),_) ->
        let tys = List.map Type_check.typ_of args in
        Typ_aux (Typ_tup tys,Unknown)
     | _ -> Type_check.typ_of exp
     end
  | [exp] ->
     Type_check.typ_of exp
  | _ ->
     let tys = List.map Type_check.typ_of args in
     Typ_aux (Typ_tup tys,Unknown)

(* Check to see if we need to monomorphise a use of a constructor.  Currently
   assumes that bitvector sizes are always given as a variable; don't yet handle
   more general cases (e.g., 8 * var) *)

let refine_constructor refinements l env id args =
  match List.find (fun (id',_) -> Id.compare id id' = 0) refinements with
  | (_,irefinements) -> begin
    let (_,constr_ty) = Env.get_union_id id env in
    match constr_ty with
    (* A constructor should always have a single argument. *)
    | Typ_aux (Typ_fn ([constr_ty],_,_),_) -> begin
       let arg_ty = typ_of_args args in
       match Type_check.destruct_exist (Type_check.Env.expand_synonyms env constr_ty) with
       | None -> None
       | Some (kopts,nc,constr_ty) ->
          (* Remove existentials in argument types to prevent unification failures *)
          let unwrap (Typ_aux (t,_) as typ) = match t with
            | Typ_exist (_,_,typ) -> typ
            | _ -> typ
          in
          let arg_ty = match arg_ty with
            | Typ_aux (Typ_tup ts,annot) -> Typ_aux (Typ_tup (List.map unwrap ts),annot)
            | _ -> arg_ty
          in
          let bindings = Type_check.unify l env (tyvars_of_typ constr_ty) constr_ty arg_ty in
          let find_kopt kopt = try Some (KBindings.find (kopt_kid kopt) bindings) with Not_found -> None in
          let bindings = List.map find_kopt kopts in
          let matches_refinement (mapping,_,_) =
            List.for_all2
              (fun v (_,w) ->
                match v,w with
                | _,None -> true
                | Some (A_aux (A_nexp (Nexp_aux (Nexp_constant n, _)), _)),Some m -> Big_int.equal n m
                | _,_ -> false) bindings mapping
          in
          match List.find matches_refinement irefinements with
          | (_,new_id,_) -> Some (E_app (new_id,args))
          | exception Not_found ->
             let print_map kopt = function
               | None -> string_of_kid (kopt_kid kopt) ^ " -> _"
               | Some ta -> string_of_kid (kopt_kid kopt) ^ " -> " ^ string_of_typ_arg ta
             in
             (Reporting.print_err l "Monomorphisation"
                ("Unable to refine constructor " ^ string_of_id id ^ " using mapping " ^ String.concat "," (List.map2 print_map kopts bindings));
              None)
    end
    | _ -> None
  end
  | exception Not_found -> None


type pat_choice = Parse_ast.l * (int * int * (id * tannot exp) list)

(* We may need to split up a pattern match if (1) we've been told to case split
   on a variable by the user or analysis, or (2) we monomorphised a constructor that's used
   in the pattern. *)
type split =
  | NoSplit
  | VarSplit of (tannot pat *        (* pattern for this case *)
      (id * tannot Ast.exp) list *   (* substitutions for arguments *)
      pat_choice list * (* optional locations of constraints/case expressions to reduce *)
      nexp KBindings.t)             (* substitutions for type variables *)
      list
  | ConstrSplit of (tannot pat * nexp KBindings.t) list

let isubst_minus subst subst' =
  Bindings.merge (fun _ x y -> match x,y with (Some a), None -> Some a | _, _ -> None) subst subst'

let freshen_id =
  let counter = ref 0 in
  fun id ->
    let n = !counter in
    let () = counter := n + 1 in
    match id with
    | Id_aux (Id x, l) -> Id_aux (Id (x ^ "#m" ^ string_of_int n),Generated l)
    | Id_aux (Operator x, l) -> Id_aux (Operator (x ^ "#m" ^ string_of_int n),Generated l)

(* TODO: only freshen bindings that might be shadowed *)
let rec freshen_pat_bindings p =
  let rec aux (P_aux (p,(l,annot)) as pat) =
    let mkp p = P_aux (p,(Generated l, annot)) in
    match p with
    | P_lit _
    | P_wild -> pat, []
    | P_or (p1, p2) ->
       let (r1, vs1) = aux p1 in
       let (r2, vs2) = aux p2 in
       (mkp (P_or (r1, r2)), vs1 @ vs2)
    | P_not p ->
       let (r, vs) = aux p in
       (mkp (P_not r), vs)
    | P_as (p,_) -> aux p
    | P_typ (typ,p) -> let p',vs = aux p in mkp (P_typ (typ,p')),vs
    | P_id id -> let id' = freshen_id id in mkp (P_id id'),[id,E_aux (E_id id',(Generated Unknown,empty_tannot))]
    | P_var (p,_) -> aux p
    | P_app (id,args) ->
       let args',vs = List.split (List.map aux args) in
       mkp (P_app (id,args')),List.concat vs
    | P_record (fpats,flag) ->
       let fpats,vs = List.split (List.map auxr fpats) in
       mkp (P_record (fpats,flag)),List.concat vs
    | P_vector ps ->
       let ps,vs = List.split (List.map aux ps) in
       mkp (P_vector ps),List.concat vs
    | P_vector_concat ps ->
       let ps,vs = List.split (List.map aux ps) in
       mkp (P_vector_concat ps),List.concat vs
    | P_string_append ps ->
       let ps,vs = List.split (List.map aux ps) in
       mkp (P_string_append ps),List.concat vs
    | P_tup ps ->
       let ps,vs = List.split (List.map aux ps) in
       mkp (P_tup ps),List.concat vs
    | P_list ps ->
       let ps,vs = List.split (List.map aux ps) in
       mkp (P_list ps),List.concat vs
    | P_cons (p1,p2) ->
       let p1,vs1 = aux p1 in
       let p2,vs2 = aux p2 in
       mkp (P_cons (p1, p2)), vs1@vs2
  and auxr (FP_aux (FP_Fpat (id,p),(l,annot))) =
    let p,vs = aux p in
    FP_aux (FP_Fpat (id, p),(Generated l,annot)), vs
  in aux p

(* This cuts off function bodies at false assertions that we may have produced
   in a wildcard pattern match.  It should handle the same assertions that
   find_set_assertions does. *)
let stop_at_false_assertions e =
  let dummy_value_of_typ typ =
    let l = Generated Unknown in
    E_aux (E_exit (E_aux (E_lit (L_aux (L_unit,l)),(l,empty_tannot))),(l,empty_tannot))
  in
  let rec nc_false (NC_aux (nc,_)) =
    match nc with
    | NC_false -> true
    | NC_and (nc1,nc2) -> nc_false nc1 || nc_false nc2
    | _ -> false
  in
  let rec exp_false (E_aux (e,_)) =
    match e with
    | E_constraint nc -> nc_false nc
    | E_lit (L_aux (L_false,_)) -> true
    | E_app (Id_aux (Id "and_bool",_),[e1;e2]) ->
       exp_false e1 || exp_false e2
    | _ -> false
  in
  let rec exp (E_aux (e,ann) as ea) =
    match e with
    | E_block es ->
       let rec aux = function
         | [] -> [], None
         | e::es -> let e,stop = exp e in
                    match stop with
                    | Some _ -> [e],stop
                    | None ->
                       let es',stop = aux es in
                       e::es',stop
       in let es,stop = aux es in begin
          match stop with
          | None -> E_aux (E_block es,ann), stop
          | Some typ ->
             let typ' = typ_of_annot ann in
             if Type_check.alpha_equivalent (env_of_annot ann) typ typ'
             then E_aux (E_block es,ann), stop
             else E_aux (E_block (es@[dummy_value_of_typ typ']),ann), Some typ'
       end
    | E_cast (typ,e) -> let e,stop = exp e in
                        let stop = match stop with Some _ -> Some typ | None -> None in
                        E_aux (E_cast (typ,e),ann),stop
    | E_let (LB_aux (LB_val (p,e1),lbann),e2) ->
       let e1,stop = exp e1 in begin
       match stop with
       | Some _ -> e1,stop
       | None -> 
          let e2,stop = exp e2 in
          E_aux (E_let (LB_aux (LB_val (p,e1),lbann),e2),ann), stop
       end
    | E_assert (e1,_) when exp_false e1 ->
       ea, Some (typ_of_annot ann)
    | _ -> ea, None
  in fst (exp e)

(* Use the location pairs in choices to reduce case expressions at the first
   location to the given case at the second. *)
let apply_pat_choices choices =
  let rec rewrite_ncs (NC_aux (nc,l) as nconstr) =
    match nc with
    | NC_set _
    | NC_or _ -> begin
      match List.assoc l choices with
      | choice,max,_ ->
         NC_aux ((if choice < max then NC_true else NC_false), Generated l)
      | exception Not_found -> nconstr
      end
    | NC_and (nc1,nc2) -> begin
      match rewrite_ncs nc1, rewrite_ncs nc2 with
      | NC_aux (NC_false,l), _
      | _, NC_aux (NC_false,l) -> NC_aux (NC_false,l)
      | nc1,nc2 -> NC_aux (NC_and (nc1,nc2),l)
      end
    | _ -> nconstr
  in
  let rec rewrite_assert_cond (E_aux (e,(l,ann)) as exp) =
    match List.assoc l choices with
    | choice,max,_ ->
       E_aux (E_lit (L_aux ((if choice < max then L_true else L_false (* wildcard *)),
         Generated l)),(Generated l,ann))
    | exception Not_found ->
       match e with
       | E_constraint nc -> E_aux (E_constraint (rewrite_ncs nc),(l,ann))
       | E_app (Id_aux (Id "and_bool",andl), [e1;e2]) ->
          E_aux (E_app (Id_aux (Id "and_bool",andl),
                        [rewrite_assert_cond e1;
                         rewrite_assert_cond e2]),(l,ann))
       | _ -> exp
  in
  let rewrite_assert (e1,e2) =
    E_assert (rewrite_assert_cond e1, e2)
  in
  let rewrite_case (e,cases) =
    match List.assoc (exp_loc e) choices with
    | choice,max,subst ->
       (match List.nth cases choice with
       | Pat_aux (Pat_exp (p,E_aux (e,_)),_) ->
          let dummyannot = (Generated Unknown,empty_tannot) in
          (* TODO: use a proper substitution *)
          List.fold_left (fun e (id,e') ->
            E_let (LB_aux (LB_val (P_aux (P_id id, dummyannot),e'),dummyannot),E_aux (e,dummyannot))) e subst
       | Pat_aux (Pat_when _,(l,_)) ->
          raise (Reporting.err_unreachable l __POS__
                   "Pattern acquired a guard after analysis!")
       | exception Not_found ->
          raise (Reporting.err_unreachable (exp_loc e) __POS__
                   "Unable to find case I found earlier!"))
    | exception Not_found -> E_case (e,cases)
  in
  let open Rewriter in
  fold_exp { id_exp_alg with
    e_assert = rewrite_assert;
    e_case = rewrite_case }

let split_defs all_errors splits env defs =
  let no_errors_happened = ref true in
  let error_opt = if all_errors then Some no_errors_happened else None in
  let split_constructors (Defs defs) =
    let sc_type_union q (Tu_aux (Tu_ty_id (ty, id), l)) =
      match split_src_type error_opt env id ty q with
      | None -> ([],[Tu_aux (Tu_ty_id (ty,id),l)])
      | Some variants ->
         ([(id,variants)],
          List.map (fun (insts, id', ty) -> Tu_aux (Tu_ty_id (ty,id'),Generated l)) variants)
    in
    let sc_type_def ((TD_aux (tda,annot)) as td) =
      match tda with
      | TD_variant (id,quant,tus,flag) ->
         let (refinements, tus') = List.split (List.map (sc_type_union quant) tus) in
         (List.concat refinements, TD_aux (TD_variant (id,quant,List.concat tus',flag),annot))
      | _ -> ([],td)
    in
    let sc_def d =
      match d with
    | DEF_type td -> let (refinements,td') = sc_type_def td in (refinements, DEF_type td')
    | _ -> ([], d)
    in
    let (refinements, defs') = List.split (List.map sc_def defs)
    in (List.concat refinements, Defs defs')
  in

  let (refinements, defs') = split_constructors defs in

  let subst_exp ref_vars substs ksubsts exp =
    let substs = bindings_from_list substs, ksubsts in
    fst (Constant_propagation.const_prop defs ref_vars substs Bindings.empty exp)
  in

  (* Split a variable pattern into every possible value *)

  let split var pat_l annot =
    let v = string_of_id var in
    let env = Type_check.env_of_annot (pat_l, annot) in
    let typ = Type_check.typ_of_annot (pat_l, annot) in
    let typ = Env.expand_synonyms env typ in
    let Typ_aux (ty,l) = typ in
    let new_l = Generated l in
    let renew_id (Id_aux (id,l)) = Id_aux (id,new_l) in
    let cannot msg =
      let open Reporting in
      let error =
        Err_general (pat_l,
                     ("Cannot split type " ^ string_of_typ typ ^ " for variable " ^ v ^ ": " ^ msg))
      in if all_errors
        then (no_errors_happened := false;
              print_error error;
              [P_aux (P_id var,(pat_l,annot)),[],[],KBindings.empty])
        else raise (Fatal_error error)
    in
    match ty with
    | Typ_id (Id_aux (Id "bool",_)) | Typ_app (Id_aux (Id "atom_bool", _), [_]) ->
       [P_aux (P_lit (L_aux (L_true,new_l)),(l,annot)),[var, E_aux (E_lit (L_aux (L_true,new_l)),(new_l,annot))],[],KBindings.empty;
        P_aux (P_lit (L_aux (L_false,new_l)),(l,annot)),[var, E_aux (E_lit (L_aux (L_false,new_l)),(new_l,annot))],[],KBindings.empty]

    | Typ_id id ->
       (try
         (* enumerations *)
         let ns = Env.get_enum id env in
         List.map (fun n -> (P_aux (P_id (renew_id n),(l,annot)),
                             [var,E_aux (E_id (renew_id n),(new_l,annot))],[],KBindings.empty)) ns
       with Type_error _ ->
         match id with
         | Id_aux (Id "bit",_) ->
            List.map (fun b ->
              P_aux (P_lit (L_aux (b,new_l)),(l,annot)),
              [var,E_aux (E_lit (L_aux (b,new_l)),(new_l, annot))],[],KBindings.empty)
              [L_zero; L_one]
         | _ -> cannot ("don't know about type " ^ string_of_id id))

    | Typ_app (Id_aux (Id "vector",_), [A_aux (A_nexp len,_);_;A_aux (A_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_)]) ->
       (match len with
       | Nexp_aux (Nexp_constant sz,_) when Big_int.greater_equal sz Big_int.zero ->
          let sz = Big_int.to_int sz in
          let num_lits = Big_int.pow_int (Big_int.of_int 2) sz in
          (* Check that split size is within limits before generating the list of literals *)
          if (Big_int.less_equal num_lits (Big_int.of_int size_set_limit)) then
            let lits = make_vectors sz in
            List.map (fun lit ->
              P_aux (P_lit lit,(l,annot)),
              [var,E_aux (E_lit lit,(new_l,annot))],[],KBindings.empty) lits
          else
            cannot ("bitvector length outside limit, " ^ string_of_nexp len)
       | _ ->
          cannot ("length not constant and positive, " ^ string_of_nexp len)
       )
    (* set constrained numbers *)
    | Typ_app (Id_aux (Id "atom",_), [A_aux (A_nexp (Nexp_aux (value,_) as nexp),_)]) ->
       begin
         let mk_lit kid i =
            let lit = L_aux (L_num i,new_l) in
            P_aux (P_lit lit,(l,annot)),
            [var,E_aux (E_lit lit,(new_l,annot))],[],
            match kid with None -> KBindings.empty
                         | Some k -> KBindings.singleton k (nconstant i)
         in
         match value with
         | Nexp_constant i -> [mk_lit None i]
         | Nexp_var kvar ->
           let ncs = Env.get_constraints env in
           let nc = List.fold_left nc_and nc_true ncs in
           (match extract_set_nc env l kvar nc with
           | (is,_) -> List.map (mk_lit (Some kvar)) is
           | exception Reporting.Fatal_error (Reporting.Err_general (_,msg)) -> cannot msg)
         | _ -> cannot ("unsupport atom nexp " ^ string_of_nexp nexp)
       end
    | _ -> cannot ("unsupported type " ^ string_of_typ typ)
  in
  

  (* Split variable patterns at the given locations *)

  let map_locs ls (Defs defs) =
    let rec match_l = function
      | Unknown -> []
      | Unique (_, l) -> match_l l
      | Generated l -> [] (* Could do match_l l, but only want to split user-written patterns *)
      | Documented (_,l) -> match_l l
      | Range (p,q) ->
         let matches =
           List.filter (fun ((filename,line),_,_) ->
             p.Lexing.pos_fname = filename &&
               p.Lexing.pos_lnum <= line && line <= q.Lexing.pos_lnum) ls
         in List.map (fun (_,var,optpats) -> (var,optpats)) matches
    in 

    let split_pat vars p =
      let id_match = function
        | Id_aux (Id x,_) -> (try Some (List.assoc x vars) with Not_found -> None)
        | Id_aux (Operator x,_) -> (try Some (List.assoc x vars) with Not_found -> None)
      in

      let rec list f = function
        | [] -> None
        | h::t ->
           let t' =
             match list f t with
             | None -> [t,[],[],KBindings.empty]
             | Some t' -> t'
           in
           let h' =
             match f h with
             | None -> [h,[],[],KBindings.empty]
             | Some ps -> ps
           in
           let merge (h,hsubs,hpchoices,hksubs) (t,tsubs,tpchoices,tksubs) =
             if KBindings.for_all (fun kid nexp ->
                    match KBindings.find_opt kid tksubs with
                    | None -> true
                    | Some nexp' -> Nexp.compare nexp nexp' == 0) hksubs
             then Some (h::t, hsubs@tsubs, hpchoices@tpchoices,
                        KBindings.union (fun k a _ -> Some a) hksubs tksubs)
             else None
           in
           Some (List.concat
                   (List.map (fun h -> Util.map_filter (merge h) t') h'))
      in
      let rec spl (P_aux (p,(l,annot))) =
        let relist f ctx ps =
          optmap (list f ps) 
            (fun ps ->
              List.map (fun (ps,sub,pchoices,ksub) -> P_aux (ctx ps,(l,annot)),sub,pchoices,ksub) ps)
        in
        let re f p =
          optmap (spl p)
            (fun ps -> List.map (fun (p,sub,pchoices,ksub) -> (P_aux (f p,(l,annot)), sub, pchoices, ksub)) ps)
        in
        let re2 f ctx p1 p2 =
           (* Todo: I am not proud of this abuse of relist - but creating a special
            * version of re just for two entries did not seem worth it
            *)
          relist f (fun [p1'; p2'] -> ctx p1' p2') [p1; p2]
        in
        let fpat (FP_aux ((FP_Fpat (id,p),annot))) =
          optmap (spl p)
            (fun ps -> List.map (fun (p,sub,pchoices,ksub) -> FP_aux (FP_Fpat (id,p), annot), sub, pchoices, ksub) ps)
        in
        match p with
        | P_lit _
        | P_wild
          -> None
        | P_or (p1, p2) ->
           re2 spl (fun p1' p2' -> P_or (p1', p2')) p1 p2
        | P_not p ->
           (* todo: not sure that I can't split - but can't figure out how at
            * the moment *)
           raise (Reporting.err_general l
                    ("Cannot split on 'not' pattern"))
        | P_as (p',id) when id_match id <> None ->
           raise (Reporting.err_general l
                    ("Cannot split " ^ string_of_id id ^ " on 'as' pattern"))
        | P_as (p',id) ->
           re (fun p -> P_as (p,id)) p'
        | P_typ (t,p') -> re (fun p -> P_typ (t,p)) p'
        | P_var (p', (TP_aux (TP_var kid,_) as tp)) ->
           (match spl p' with
           | None -> None
           | Some ps ->
              let kids = Spec_analysis.equal_kids (env_of_pat p') kid in
              Some (List.map (fun (p,sub,pchoices,ksub) ->
                P_aux (P_var (p,tp),(l,annot)), sub, pchoices,
                match List.find_opt (fun k -> KBindings.mem k ksub) (KidSet.elements kids) with
                | None -> ksub
                | Some k -> KBindings.add kid (KBindings.find k ksub) ksub
                ) ps))
        | P_var (p',tp) -> re (fun p -> P_var (p,tp)) p'
        | P_id id ->
           (match id_match id with
           | None -> None
           (* Total case split *)
           | Some None -> Some (split id l annot)
           (* Where the analysis proposed a specific case split, propagate a
              literal as normal, but perform a more careful transformation
              otherwise *)
           | Some (Some (pats,l)) ->
              let max = List.length pats - 1 in
              let lit_like = function
                | P_lit _ -> true
                | P_vector ps -> List.for_all (function P_aux (P_lit _,_) -> true | _ -> false) ps
                | _ -> false
              in
              let rec to_exp = function
                | P_aux (P_lit lit,(l,ann)) -> E_aux (E_lit lit,(Generated l,ann))
                | P_aux (P_vector ps,(l,ann)) -> E_aux (E_vector (List.map to_exp ps),(Generated l,ann))
                | _ -> assert false
              in
              Some (List.mapi (fun i p ->
                match p with
                | P_aux (P_lit (L_aux (L_num j,_) as lit),(pl,pannot)) ->
                   let orig_typ = Env.base_typ_of (env_of_annot (l,annot)) (typ_of_annot (l,annot)) in
                   let kid_subst = match orig_typ with
                     | Typ_aux
                         (Typ_app (Id_aux (Id "atom",_),
                                   [A_aux (A_nexp
                                                   (Nexp_aux (Nexp_var var,_)),_)]),_) ->
                        KBindings.singleton var (nconstant j)
                     | _ -> KBindings.empty
                   in
                   p,[id,E_aux (E_lit lit,(Generated pl,pannot))],[l,(i,max,[])],kid_subst
                | P_aux (p',(pl,pannot)) when lit_like p' ->
                   p,[id,to_exp p],[l,(i,max,[])],KBindings.empty
                | _ ->
                   let p',subst = freshen_pat_bindings p in
                   match p' with
                   | P_aux (P_wild,_) ->
                      P_aux (P_id id,(l,annot)),[],[l,(i,max,subst)],KBindings.empty
                   | _ ->
                      P_aux (P_as (p',id),(l,annot)),[],[l,(i,max,subst)],KBindings.empty)
                      pats)
           )
        | P_app (id,ps) ->
           relist spl (fun ps -> P_app (id,ps)) ps
        | P_record (fps,flag) ->
           relist fpat (fun fps -> P_record (fps,flag)) fps
        | P_vector ps ->
           relist spl (fun ps -> P_vector ps) ps
        | P_vector_concat ps ->
           relist spl (fun ps -> P_vector_concat ps) ps
        | P_string_append ps ->
           relist spl (fun ps -> P_string_append ps) ps
        | P_tup ps ->
           relist spl (fun ps -> P_tup ps) ps
        | P_list ps ->
           relist spl (fun ps -> P_list ps) ps
        | P_cons (p1,p2) ->
           re2 spl (fun p1' p2' -> P_cons (p1', p2')) p1 p2
      in spl p
    in

    let map_pat_by_loc (P_aux (p,(l,_)) as pat) =
      match match_l l with
      | [] -> None
      | vars -> split_pat vars pat
    in
    let map_pat (P_aux (p,(l,tannot)) as pat) =
      let try_by_location () =
        match map_pat_by_loc pat with
        | Some l -> VarSplit l
        | None -> NoSplit
      in
      match p with
      | P_app (id,args) ->
         begin
            match List.find (fun (id',_) -> Id.compare id id' = 0) refinements with
            | (_,variants) ->
(* TODO: at changes to the pattern and what substitutions do we need in general?
               let kid,kid_annot =
                 match args with
                 | [P_aux (P_var (_, TP_aux (TP_var kid, _)),ann)] -> kid,ann
                 | _ -> 
                    raise (Reporting.err_general l
                             ("Pattern match not currently supported by monomorphisation: "
                             ^ string_of_pat pat))
               in
               let map_inst (insts,id',_) =
                 let insts =
                   match insts with [(v,Some i)] -> [(kid,Nexp_aux (Nexp_constant i, Generated l))]
                   | _ -> assert false
                 in
(*
                 let insts,_ = split_insts insts in
                 let insts = List.map (fun (v,i) ->
                   (??,
                    Nexp_aux (Nexp_constant i,Generated l)))
                   insts in
  P_aux (app (id',args),(Generated l,tannot)),
*)
                 P_aux (P_app (id',[P_aux (P_id (id_of_kid kid),kid_annot)]),(Generated l,tannot)),
                 kbindings_from_list insts
               in
*)
               let map_inst (insts,id',_) =
                 P_aux (P_app (id',args),(Generated l,tannot)),
                 KBindings.empty
               in
               ConstrSplit (List.map map_inst variants)
            | exception Not_found -> try_by_location ()
          end
       | _ -> try_by_location ()
    in

    let check_single_pat (P_aux (_,(l,annot)) as p) =
      match match_l l with
      | [] -> p
      | lvs ->
         let pvs = Spec_analysis.bindings_from_pat p in
         let pvs = List.map string_of_id pvs in
         let overlap = List.exists (fun (v,_) -> List.mem v pvs) lvs in
         let () =
           if overlap then
             Reporting.print_err l "Monomorphisation"
               "Splitting a singleton pattern is not possible"
         in p
    in

    let check_split_size lst l =
      let size = List.length lst in
      if size > size_set_limit then
        let open Reporting in
        let error =
          Err_general (l, "Case split is too large (" ^ string_of_int size ^
            " > limit " ^ string_of_int size_set_limit ^ ")")
        in if all_errors
          then (no_errors_happened := false;
                print_error error; false)
          else raise (Fatal_error error)
      else true
    in

    let map_fns ref_vars =
      let rec map_exp ((E_aux (e,annot)) as ea) =
        let re e = E_aux (e,annot) in
        match e with
        | E_block es -> re (E_block (List.map map_exp es))
        | E_id _
        | E_lit _
        | E_sizeof _
        | E_constraint _
        | E_ref _
        | E_internal_value _
          -> ea
        | E_cast (t,e') -> re (E_cast (t, map_exp e'))
        | E_app (id,es) ->
           let es' = List.map map_exp es in
           let env = env_of_annot annot in
           begin
             match Env.is_union_constructor id env, refine_constructor refinements (fst annot) env id es' with
             | true, Some exp -> re exp
             | _,_ -> re (E_app (id,es'))
           end
        | E_app_infix (e1,id,e2) -> re (E_app_infix (map_exp e1,id,map_exp e2))
        | E_tuple es -> re (E_tuple (List.map map_exp es))
        | E_if (e1,e2,e3) -> re (E_if (map_exp e1, map_exp e2, map_exp e3))
        | E_for (id,e1,e2,e3,ord,e4) -> re (E_for (id,map_exp e1,map_exp e2,map_exp e3,ord,map_exp e4))
        | E_loop (loop,m,e1,e2) -> re (E_loop (loop,m,map_exp e1,map_exp e2))
        | E_vector es -> re (E_vector (List.map map_exp es))
        | E_vector_access (e1,e2) -> re (E_vector_access (map_exp e1,map_exp e2))
        | E_vector_subrange (e1,e2,e3) -> re (E_vector_subrange (map_exp e1,map_exp e2,map_exp e3))
        | E_vector_update (e1,e2,e3) -> re (E_vector_update (map_exp e1,map_exp e2,map_exp e3))
        | E_vector_update_subrange (e1,e2,e3,e4) -> re (E_vector_update_subrange (map_exp e1,map_exp e2,map_exp e3,map_exp e4))
        | E_vector_append (e1,e2) -> re (E_vector_append (map_exp e1,map_exp e2))
        | E_list es -> re (E_list (List.map map_exp es))
        | E_cons (e1,e2) -> re (E_cons (map_exp e1,map_exp e2))
        | E_record fes -> re (E_record (List.map map_fexp fes))
        | E_record_update (e,fes) -> re (E_record_update (map_exp e, List.map map_fexp fes))
        | E_field (e,id) -> re (E_field (map_exp e,id))
        | E_case (e,cases) -> re (E_case (map_exp e, List.concat (List.map map_pexp cases)))
        | E_let (lb,e) -> re (E_let (map_letbind lb, map_exp e))
        | E_assign (le,e) -> re (E_assign (map_lexp le, map_exp e))
        | E_exit e -> re (E_exit (map_exp e))
        | E_throw e -> re (E_throw e)
        | E_try (e,cases) -> re (E_try (map_exp e, List.concat (List.map map_pexp cases)))
        | E_return e -> re (E_return (map_exp e))
        | E_assert (e1,e2) -> re (E_assert (map_exp e1,map_exp e2))
        | E_var (le,e1,e2) -> re (E_var (map_lexp le, map_exp e1, map_exp e2))
        | E_internal_plet (p,e1,e2) -> re (E_internal_plet (check_single_pat p, map_exp e1, map_exp e2))
        | E_internal_return e -> re (E_internal_return (map_exp e))
      and map_fexp (FE_aux (FE_Fexp (id,e), annot)) =
        FE_aux (FE_Fexp (id,map_exp e),annot)
      and map_pexp = function
        | Pat_aux (Pat_exp (p,e),l) ->
           let nosplit = lazy [Pat_aux (Pat_exp (p,map_exp e),l)] in
           (match map_pat p with
           | NoSplit -> Lazy.force nosplit
           | VarSplit patsubsts ->
              if check_split_size patsubsts (pat_loc p) then
                List.map (fun (pat',substs,pchoices,ksubsts) ->
                  let exp' = Spec_analysis.nexp_subst_exp ksubsts e in
                  let exp' = subst_exp ref_vars substs ksubsts exp' in
                  let exp' = apply_pat_choices pchoices exp' in
                  let exp' = stop_at_false_assertions exp' in
                  Pat_aux (Pat_exp (pat', map_exp exp'),l))
                  patsubsts
              else Lazy.force nosplit
           | ConstrSplit patnsubsts ->
              List.map (fun (pat',nsubst) ->
                let pat' = Spec_analysis.nexp_subst_pat nsubst pat' in
                let exp' = Spec_analysis.nexp_subst_exp nsubst e in
                Pat_aux (Pat_exp (pat', map_exp exp'),l)
              ) patnsubsts)
        | Pat_aux (Pat_when (p,e1,e2),l) ->
           let nosplit = lazy [Pat_aux (Pat_when (p,map_exp e1,map_exp e2),l)] in
           (match map_pat p with
           | NoSplit -> Lazy.force nosplit
           | VarSplit patsubsts ->
              if check_split_size patsubsts (pat_loc p) then
                List.map (fun (pat',substs,pchoices,ksubsts) ->
                  let exp1' = Spec_analysis.nexp_subst_exp ksubsts e1 in
                  let exp1' = subst_exp ref_vars substs ksubsts exp1' in
                  let exp1' = apply_pat_choices pchoices exp1' in
                  let exp2' = Spec_analysis.nexp_subst_exp ksubsts e2 in
                  let exp2' = subst_exp ref_vars substs ksubsts exp2' in
                  let exp2' = apply_pat_choices pchoices exp2' in
                  let exp2' = stop_at_false_assertions exp2' in
                  Pat_aux (Pat_when (pat', map_exp exp1', map_exp exp2'),l))
                  patsubsts
              else Lazy.force nosplit
           | ConstrSplit patnsubsts ->
              List.map (fun (pat',nsubst) ->
                let pat' = Spec_analysis.nexp_subst_pat nsubst pat' in
                let exp1' = Spec_analysis.nexp_subst_exp nsubst e1 in
                let exp2' = Spec_analysis.nexp_subst_exp nsubst e2 in
                Pat_aux (Pat_when (pat', map_exp exp1', map_exp exp2'),l)
              ) patnsubsts)
      and map_letbind (LB_aux (lb,annot)) =
        match lb with
        | LB_val (p,e) -> LB_aux (LB_val (check_single_pat p,map_exp e), annot)
      and map_lexp ((LEXP_aux (e,annot)) as le) =
        let re e = LEXP_aux (e,annot) in
        match e with
        | LEXP_id _
        | LEXP_cast _
          -> le
        | LEXP_memory (id,es) -> re (LEXP_memory (id,List.map map_exp es))
        | LEXP_tup les -> re (LEXP_tup (List.map map_lexp les))
        | LEXP_vector (le,e) -> re (LEXP_vector (map_lexp le, map_exp e))
        | LEXP_vector_range (le,e1,e2) -> re (LEXP_vector_range (map_lexp le, map_exp e1, map_exp e2))
        | LEXP_vector_concat les -> re (LEXP_vector_concat (List.map map_lexp les))
        | LEXP_field (le,id) -> re (LEXP_field (map_lexp le, id))
        | LEXP_deref e -> re (LEXP_deref (map_exp e))
      in map_exp, map_pexp, map_letbind
    in
    let map_exp r = let (f,_,_) = map_fns r in f in
    let map_pexp r = let (_,f,_) = map_fns r in f in
    let map_letbind r = let (_,_,f) = map_fns r in f in
    let map_exp exp =
      let ref_vars = Constant_propagation.referenced_vars exp in
      map_exp ref_vars exp
    in
    let map_pexp top_pexp =
      (* Construct the set of referenced variables so that we don't accidentally
         make false assumptions about them during constant propagation.  Note that
         we assume there aren't any in the guard. *)
      let (_,_,body,_) = destruct_pexp top_pexp in
      let ref_vars = Constant_propagation.referenced_vars body in
      map_pexp ref_vars top_pexp
    in
    let map_letbind (LB_aux (LB_val (_,e),_) as lb) =
      let ref_vars = Constant_propagation.referenced_vars e in
      map_letbind ref_vars lb
    in

    let map_funcl (FCL_aux (FCL_Funcl (id,pexp),annot)) =
      List.map (fun pexp -> FCL_aux (FCL_Funcl (id,pexp),annot)) (map_pexp pexp)
    in

    let map_fundef (FD_aux (FD_function (r,t,e,fcls),annot)) =
      FD_aux (FD_function (r,t,e,List.concat (List.map map_funcl fcls)),annot)
    in
    let map_scattered_def sd =
      match sd with
      | SD_aux (SD_funcl fcl, annot) ->
         List.map (fun fcl' -> SD_aux (SD_funcl fcl', annot)) (map_funcl fcl)
      | _ -> [sd]
    in
    let map_def d =
      match d with
      | DEF_type _
      | DEF_spec _
      | DEF_default _
      | DEF_reg_dec _
      | DEF_overload _
      | DEF_fixity _
      | DEF_pragma _
      | DEF_internal_mutrec _
        -> [d]
      | DEF_fundef fd -> [DEF_fundef (map_fundef fd)]
      | DEF_mapdef (MD_aux (_, (l, _))) ->
         Reporting.unreachable l __POS__ "mappings should be gone by now"
      | DEF_val lb -> [DEF_val (map_letbind lb)]
      | DEF_scattered sd -> List.map (fun x -> DEF_scattered x) (map_scattered_def sd)
      | DEF_measure (id,pat,exp) -> [DEF_measure (id,pat,map_exp exp)]
      | DEF_loop_measures (id,_) ->
         Reporting.unreachable (id_loc id) __POS__
           "Loop termination measures should have been rewritten before now"
    in
    Defs (List.concat (List.map map_def defs))
  in
  let defs'' = map_locs splits defs' in
  !no_errors_happened, defs''



(* The next section of code turns atom('n) types into itself('n) types, which
   survive into the Lem output, so can be used to parametrise functions over
   internal bitvector lengths (such as datasize and regsize in ARM specs *)

module AtomToItself =
struct

let findi f =
  let rec aux n = function
    | [] -> None
    | h::t -> match f h with Some x -> Some (n,x) | _ -> aux (n+1) t
  in aux 0

let mapat f is xs =
  let rec aux n = function
    | [] -> []
    | h::t when Util.IntSet.mem n is ->
       let h' = f h in
       let t' = aux (n+1) t in
       h'::t'
    | h::t ->
       let t' = aux (n+1) t in
       h::t'
  in aux 0 xs

let mapat_extra f is xs =
  let rec aux n = function
    | [] -> [], []
    | h::t when Util.IntSet.mem n is ->
       let h',x = f n h in
       let t',xs = aux (n+1) t in
       h'::t',x::xs
    | h::t ->
       let t',xs = aux (n+1) t in
       h::t',xs
  in aux 0 xs

let tyvars_bound_in_pat pat =
  let rec tp_kids s (TP_aux (tp,_)) =
    match tp with
    | TP_wild -> s
    | TP_var kid -> KidSet.add kid s
    | TP_app (_,tps) -> List.fold_left tp_kids s tps
  in
  let open Rewriter in
  fst (fold_pat
         { (compute_pat_alg KidSet.empty KidSet.union) with
           p_var = (fun ((s,pat), tpat) ->
                     tp_kids s tpat, P_var (pat, tpat)) }
         pat)
let tyvars_bound_in_lb (LB_aux (LB_val (pat,_),_)) = tyvars_bound_in_pat pat

let rec sizes_of_typ (Typ_aux (t,l)) =
  match t with
  | Typ_id _
  | Typ_var _
    -> KidSet.empty
  | Typ_fn _ -> raise (Reporting.err_general l
                         "Function type on expression")
  | Typ_bidir _ -> raise (Reporting.err_general l "Mapping type on expression")
  | Typ_tup typs -> kidset_bigunion (List.map sizes_of_typ typs)
  | Typ_exist (kopts,_,typ) ->
     List.fold_left (fun s k -> KidSet.remove (kopt_kid k) s) (sizes_of_typ typ) kopts
  | Typ_app (Id_aux (Id "vector",_),
             [A_aux (A_nexp size,_);
              _;A_aux (A_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_)]) ->
     KidSet.of_list (size_nvars_nexp size)
  | Typ_app (_,tas) ->
     kidset_bigunion (List.map sizes_of_typarg tas)
  | Typ_internal_unknown -> Reporting.unreachable l __POS__ "escaped Typ_internal_unknown"
and sizes_of_typarg (A_aux (ta,_)) =
  match ta with
    A_nexp _
  | A_order _
  | A_bool _
    -> KidSet.empty
  | A_typ typ -> sizes_of_typ typ

let sizes_of_annot (l, tannot) =
  match destruct_tannot tannot with
  | None -> KidSet.empty
  | Some (env,typ,_) -> sizes_of_typ (Env.base_typ_of env typ)

let change_parameter_pat i = function
  | P_aux (P_id var, (l,_))
  | P_aux (P_typ (_,P_aux (P_id var, (l,_))),_) ->
     P_aux (P_id var, (l,empty_tannot)), ([var],[])
  | P_aux (P_lit lit,(l,_)) ->
     let var = mk_id ("p#" ^ string_of_int i) in
     let annot = (Generated l, empty_tannot) in
     let test : tannot exp =
       E_aux (E_app_infix (E_aux (E_app (mk_id "size_itself_int",[E_aux (E_id var,annot)]),annot),
                           mk_id "==",
                           E_aux (E_lit lit,annot)), annot) in
     P_aux (P_id var, (l,empty_tannot)), ([],[test])
  | P_aux (_,(l,_)) -> raise (Reporting.err_unreachable l __POS__
                                "Expected variable pattern")

(* TODO: make more precise, preferably with a proper free variables function
   which deals with shadowing *)
let var_maybe_used_in_exp exp var =
  let open Rewriter in
  fst (fold_exp {
    (compute_exp_alg false (||)) with
      e_id = fun id -> (Id.compare id var == 0, E_id id) } exp)

(* We add code to change the itself('n) parameter into the corresponding
   integer.  We always do this for the function body (otherwise we'd have to do
   something clever with E_sizeof to avoid making things more complex), but
   only for guards when they actually use the variable. *)
let add_var_rebind unconditional exp var =
  if unconditional || var_maybe_used_in_exp exp var then
    let l = Generated Unknown in
    let annot = (l,empty_tannot) in
    E_aux (E_let (LB_aux (LB_val (P_aux (P_id var,annot),
                                  E_aux (E_app (mk_id "size_itself_int",[E_aux (E_id var,annot)]),annot)),annot),exp),annot)
  else exp

(* atom('n) arguments to function calls need to be rewritten *)
let replace_with_the_value bound_nexps (E_aux (_,(l,_)) as exp) =
  let env = env_of exp in
  let typ, wrap = match typ_of exp with
    | Typ_aux (Typ_exist (kids,nc,typ),l) -> typ, fun t -> Typ_aux (Typ_exist (kids,nc,t),l)
    | typ -> typ, fun x -> x
  in
  let typ = Env.expand_synonyms env typ in
  let replace_size size = 
    (* TODO: pick simpler nexp when there's a choice (also in pretty printer) *)
    let is_equal nexp =
      prove __POS__ env (NC_aux (NC_equal (size,nexp), Parse_ast.Unknown))
    in
    if is_nexp_constant size then size else
      match solve_unique env size with
      | Some n -> nconstant n
      | None ->
         match List.find is_equal bound_nexps with
         | nexp -> nexp
         | exception Not_found -> size
  in
  let mk_exp nexp l l' =
    let nexp = replace_size nexp in
    E_aux (E_cast (wrap (Typ_aux (Typ_app (Id_aux (Id "itself",Generated Unknown),
                                           [A_aux (A_nexp nexp,l')]),Generated Unknown)),
                   E_aux (E_app (Id_aux (Id "make_the_value",Generated Unknown),[exp]),(Generated l,empty_tannot))),
           (Generated l,empty_tannot))
  in
  match destruct_numeric typ with
  | Some ([], nc, nexp) when prove __POS__ env nc -> mk_exp nexp l l
  | _ -> raise (Reporting.err_unreachable l __POS__
                  ("replace_with_the_value: Unsupported type " ^ string_of_typ typ))

let replace_type env typ =
  let Typ_aux (t,l) = Env.expand_synonyms env typ in
  match destruct_numeric typ with
  | Some ([], nc, nexp) when prove __POS__ env nc ->
     Typ_aux (Typ_app (mk_id "itself", [A_aux (A_nexp nexp, Generated l)]), Generated l)
  | _ -> raise (Reporting.err_unreachable l __POS__
                  ("replace_type: Unsupported type " ^ string_of_typ typ))


let rewrite_size_parameters env (Defs defs) =
  let open Rewriter in
  let open Util in

  let sizes_funcl fsizes (FCL_aux (FCL_Funcl (id,pexp),(l,ann))) =
    let pat,guard,exp,pannot = destruct_pexp pexp in
    let env = env_of_annot (l,ann) in
    let _, typ = Env.get_val_spec_orig id env in
    let already_visible_nexps =
      NexpSet.union
         (Pretty_print_lem.lem_nexps_of_typ typ)
         (Pretty_print_lem.typeclass_nexps typ)
    in
    let types = match typ with
      | Typ_aux (Typ_fn (arg_typs,_,_),_) -> List.map (Env.expand_synonyms env) arg_typs
      | _ -> raise (Reporting.err_unreachable l __POS__ "Function clause does not have a function type")
    in
    let add_parameter (i,nmap) typ =
      let nmap =
        match Env.base_typ_of env typ with
          Typ_aux (Typ_app(Id_aux (Id "range",_),
                           [A_aux (A_nexp nexp,_);
                            A_aux (A_nexp nexp',_)]),_)
            when Nexp.compare nexp nexp' = 0 && not (NexpMap.mem nexp nmap) &&
                 not (NexpSet.mem nexp already_visible_nexps) ->
           (* Split integer variables if the nexp is not already available via a bitvector length *)
           NexpMap.add nexp i nmap
        | Typ_aux (Typ_app(Id_aux (Id "atom", _),
                           [A_aux (A_nexp nexp,_)]), _)
            when not (NexpMap.mem nexp nmap) &&
                 not (NexpSet.mem nexp already_visible_nexps) ->
           NexpMap.add nexp i nmap
        | _ -> nmap
      in (i+1,nmap)
    in
    let (_,nexp_map) = List.fold_left add_parameter (0,NexpMap.empty) types in
    let nexp_list = NexpMap.bindings nexp_map in
(* let () =
 print_endline ("Type of pattern for " ^ string_of_id id ^": " ^string_of_typ (typ_of_pat pat));
 print_endline ("Types : " ^ String.concat ", " (List.map string_of_typ types));
 print_endline ("Nexp map for " ^ string_of_id id);
 List.iter (fun (nexp, i) -> print_endline ("  " ^ string_of_nexp nexp ^ " -> " ^ string_of_int i)) nexp_list
in *)
    let parameters_for tannot =
      match destruct_tannot tannot with
      | Some (env,typ,_) ->
         begin match Env.base_typ_of env typ with
         | Typ_aux (Typ_app (Id_aux (Id "vector",_), [A_aux (A_nexp size,_);_;_]),_)
             when not (is_nexp_constant size) ->
            begin
              match NexpMap.find size nexp_map with
              | i -> IntSet.singleton i
              | exception Not_found ->
                 (* Look for equivalent nexps, but only in consistent type env *)
                 if prove __POS__ env (NC_aux (NC_false,Unknown)) then IntSet.empty else
                   match List.find (fun (nexp,i) -> 
                     prove __POS__ env (NC_aux (NC_equal (nexp,size),Unknown))) nexp_list with
                   | _, i -> IntSet.singleton i
                   | exception Not_found -> IntSet.empty
          end
         | _ -> IntSet.empty
         end
      | None -> IntSet.empty
    in
    let parameters_to_rewrite =
      fst (fold_pexp
             { (compute_exp_alg IntSet.empty IntSet.union) with
               e_aux = (fun ((s,e),(l,annot)) -> IntSet.union s (parameters_for annot),E_aux (e,(l,annot)))
             } pexp)
    in
    let new_nexps = NexpSet.of_list (List.map fst
      (List.filter (fun (nexp,i) -> IntSet.mem i parameters_to_rewrite) nexp_list)) in
    match Bindings.find id fsizes with
    | old,old_nexps -> Bindings.add id (IntSet.union old parameters_to_rewrite,
                                        NexpSet.union old_nexps new_nexps) fsizes
    | exception Not_found -> Bindings.add id (parameters_to_rewrite, new_nexps) fsizes
  in
  let sizes_def fsizes = function
    | DEF_fundef (FD_aux (FD_function (_,_,_,funcls),_)) ->
       List.fold_left sizes_funcl fsizes funcls
    | _ -> fsizes
  in
  let fn_sizes = List.fold_left sizes_def Bindings.empty defs in

  let rewrite_funcl (FCL_aux (FCL_Funcl (id,pexp),(l,annot))) =
    let pat,guard,body,(pl,_) = destruct_pexp pexp in
    let pat,guard,body, nexps =
      (* Update pattern and add itself -> nat wrapper to body *)
      match Bindings.find id fn_sizes with
      | to_change,nexps ->
         let pat, vars, new_guards =
           match pat with
             P_aux (P_tup pats,(l,_)) ->
               let pats, vars_guards = mapat_extra change_parameter_pat to_change pats in
               let vars, new_guards = List.split vars_guards in
               P_aux (P_tup pats,(l,empty_tannot)), vars, new_guards
           | P_aux (_,(l,_)) ->
              begin
                if IntSet.is_empty to_change then pat, [], []
                else
                   let pat, (var, newguard) = change_parameter_pat 0 pat in
                   pat, [var], [newguard]
              end
         in
         let vars, new_guards = List.concat vars, List.concat new_guards in
         let body = List.fold_left (add_var_rebind true) body vars in
         let merge_guards g1 g2 : tannot exp =
           E_aux (E_app_infix (g1, mk_id "&", g2),(Generated Unknown,empty_tannot)) in
         let guard = match guard, new_guards with
           | None, [] -> None
           | None, (h::t) -> Some (List.fold_left merge_guards h t)
           | Some exp, gs ->
              let exp' = List.fold_left (add_var_rebind false) exp vars in
              Some (List.fold_left merge_guards exp' gs)
         in
         pat,guard,body,nexps
      | exception Not_found -> pat,guard,body,NexpSet.empty
    in
    (* Update function applications *)
    let funcl_typ = typ_of_annot (l,annot) in
    let already_visible_nexps =
      NexpSet.union
         (Pretty_print_lem.lem_nexps_of_typ funcl_typ)
         (Pretty_print_lem.typeclass_nexps funcl_typ)
    in
    let bound_nexps = NexpSet.elements (NexpSet.union nexps already_visible_nexps) in
    let rewrite_e_app (id,args) =
      match Bindings.find id fn_sizes with
      | to_change,_ ->
         let args' = mapat (replace_with_the_value bound_nexps) to_change args in
         E_app (id,args')
      | exception Not_found -> E_app (id,args)
    in
    let body = fold_exp { id_exp_alg with e_app = rewrite_e_app } body in
    let guard = match guard with
      | None -> None
      | Some exp -> Some (fold_exp { id_exp_alg with e_app = rewrite_e_app } exp) in
    FCL_aux (FCL_Funcl (id,construct_pexp (pat,guard,body,(pl,empty_tannot))),(l,empty_tannot))
  in
  let rewrite_e_app (id,args) =
    match Bindings.find id fn_sizes with
    | to_change,_ ->
       let args' = mapat (replace_with_the_value []) to_change args in
       E_app (id,args')
    | exception Not_found -> E_app (id,args)
  in
  let rewrite_letbind = fold_letbind { id_exp_alg with e_app = rewrite_e_app } in
  let rewrite_exp = fold_exp { id_exp_alg with e_app = rewrite_e_app } in
  let rewrite_def = function
    | DEF_fundef (FD_aux (FD_function (recopt,tannopt,effopt,funcls),(l,_))) ->
       (* TODO rewrite tannopt? *)
       DEF_fundef (FD_aux (FD_function (recopt,tannopt,effopt,List.map rewrite_funcl funcls),(l,empty_tannot)))
    | DEF_val lb -> DEF_val (rewrite_letbind lb)
    | DEF_spec (VS_aux (VS_val_spec (typschm,id,extern,cast),(l,annot))) as spec ->
       begin
         match Bindings.find id fn_sizes with
         | to_change,_ when not (IntSet.is_empty to_change) ->
            let typschm = match typschm with
              | TypSchm_aux (TypSchm_ts (tq,typ),l) ->
                 let typ = match typ with
                   | Typ_aux (Typ_fn (ts,t2,eff),l2) ->
                      Typ_aux (Typ_fn (mapat (replace_type env) to_change ts,t2,eff),l2)
                   | _ -> replace_type env typ
                 in TypSchm_aux (TypSchm_ts (tq,typ),l)
            in
            DEF_spec (VS_aux (VS_val_spec (typschm,id,extern,cast),(l,empty_tannot)))
         | _ -> spec
         | exception Not_found -> spec
       end
    | DEF_reg_dec (DEC_aux (DEC_config (id, typ, exp), a)) ->
       DEF_reg_dec (DEC_aux (DEC_config (id, typ, rewrite_exp exp), a))
    | def -> def
  in
(*
  Bindings.iter (fun id args ->
    print_endline (string_of_id id ^ " needs " ^
                     String.concat ", " (List.map string_of_int args))) fn_sizes
*)
  Defs (List.map rewrite_def defs)

end


let is_id env id =
  let ids = Env.get_overloads (Id_aux (id,Parse_ast.Unknown)) env in
  let ids = id :: List.map (fun (Id_aux (id,_)) -> id) ids in
  fun (Id_aux (x,_)) -> List.mem x ids

(* Type-agnostic pattern comparison for merging below *)

let lit_eq' (L_aux (l1,_)) (L_aux (l2,_)) =
  match l1, l2 with
  | L_num n1, L_num n2 -> Big_int.equal n1 n2
  | _,_ -> l1 = l2

let forall2 p x y =
  try List.for_all2 p x y with Invalid_argument _ -> false

let rec typ_pat_eq (TP_aux (tp1, _)) (TP_aux (tp2, _)) =
  match tp1, tp2 with
  | TP_wild, TP_wild -> true
  | TP_var kid1, TP_var kid2 -> Kid.compare kid1 kid2 = 0
  | TP_app (f1, args1), TP_app (f2, args2) when List.length args1 = List.length args2 ->
     Id.compare f1 f2 = 0 && List.for_all2 typ_pat_eq args1 args2
  | _, _ -> false

let rec pat_eq (P_aux (p1,_)) (P_aux (p2,_)) =
  match p1, p2 with
  | P_lit lit1, P_lit lit2 -> lit_eq' lit1 lit2
  | P_wild, P_wild -> true
  | P_or (p1, q1), P_or (p2, q2) ->
     (* ToDo: A case could be made for flattening trees of P_or nodes and
      * comparing the lists so that we treat P_or as associative
      *)
     pat_eq p1 p2 && pat_eq q1 q2
  | P_not(p1), P_not(p2) -> pat_eq p1 p2
  | P_as (p1',id1), P_as (p2',id2) -> Id.compare id1 id2 == 0 && pat_eq p1' p2'
  | P_typ (_,p1'), P_typ (_,p2') -> pat_eq p1' p2'
  | P_id id1, P_id id2 -> Id.compare id1 id2 == 0
  | P_var (p1', tpat1), P_var (p2', tpat2) -> typ_pat_eq tpat1 tpat2 && pat_eq p1' p2'
  | P_app (id1,args1), P_app (id2,args2) ->
     Id.compare id1 id2 == 0 && forall2 pat_eq args1 args2
  | P_record (fpats1, flag1), P_record (fpats2, flag2) ->
     flag1 == flag2 && forall2 fpat_eq fpats1 fpats2
  | P_vector ps1, P_vector ps2
  | P_vector_concat ps1, P_vector_concat ps2
  | P_tup ps1, P_tup ps2
  | P_list ps1, P_list ps2 -> List.for_all2 pat_eq ps1 ps2
  | P_cons (p1',p1''), P_cons (p2',p2'') -> pat_eq p1' p2' && pat_eq p1'' p2''
  | _,_ -> false
and fpat_eq (FP_aux (FP_Fpat (id1,p1),_)) (FP_aux (FP_Fpat (id2,p2),_)) =
  Id.compare id1 id2 == 0 && pat_eq p1 p2



module Analysis =
struct

type loc = string * int (* filename, line *)

let string_of_loc (s,l) = s ^ "." ^ string_of_int l

let id_pair_compare (id,l) (id',l') =
    match Id.compare id id' with
    | 0 -> compare l l'
    | x -> x

(* Usually we do a full case split on an argument, but sometimes we find a
   case expression in the function body that suggests a more compact case
   splitting. *)
type match_detail =
  | Total
  | Partial of tannot pat list * Parse_ast.l

(* Arguments that we might split on *)
module ArgSplits = Map.Make (struct
  type t = id * loc
  let compare = id_pair_compare
end)
type arg_splits = match_detail ArgSplits.t

(* Function id, funcl loc for adding splits on sizes in the body when
   there's no corresponding argument *)
module ExtraSplits = Map.Make (struct
  type t = id * Parse_ast.l
  let compare (id,l) (id',l') =
    let x = Id.compare id id' in
    if x <> 0 then x else
      compare l l'
end)
type extra_splits = (match_detail KBindings.t) ExtraSplits.t

(* Arguments that we should look at in callers *)
module CallerArgSet = Set.Make (struct
  type t = id * int
  let compare = id_pair_compare
end)

(* Type variables that we should look at in callers *)
module CallerKidSet = Set.Make (struct
  type t = id * kid
  let compare (id,kid) (id',kid') =
    match Id.compare id id' with
    | 0 -> Kid.compare kid kid'
    | x -> x
end)

(* Map from locations to string sets *)
module Failures = Map.Make (struct
  type t = Parse_ast.l
  let compare = compare
end)
module StringSet = Set.Make (struct
  type t = string
  let compare = compare
end)

type dependencies =
  | Have of arg_splits * extra_splits
  | Unknown of Parse_ast.l * string

let string_of_match_detail = function
  | Total -> "[total]"
  | Partial (pats,_) -> "[" ^ String.concat " | " (List.map string_of_pat pats) ^ "]"

let string_of_argsplits s =
  String.concat ", "
    (List.map (fun ((id,l),detail) ->
      string_of_id id ^ "." ^ string_of_loc l ^ string_of_match_detail detail)
                        (ArgSplits.bindings s))

let string_of_lx lx =
  let open Lexing in
  Printf.sprintf "%s,%d,%d,%d" lx.pos_fname lx.pos_lnum lx.pos_bol lx.pos_cnum

let rec simple_string_of_loc = function
  | Parse_ast.Unknown -> "Unknown"
  | Parse_ast.Unique (n, l) -> "Unique(" ^ string_of_int n ^ ", " ^ simple_string_of_loc l ^ ")"
  | Parse_ast.Generated l -> "Generated(" ^ simple_string_of_loc l ^ ")"
  | Parse_ast.Range (lx1,lx2) -> "Range(" ^ string_of_lx lx1 ^ "->" ^ string_of_lx lx2 ^ ")"
  | Parse_ast.Documented (_,l) -> "Documented(_," ^ simple_string_of_loc l ^ ")"

let string_of_extra_splits s =
  String.concat ", "
    (List.map (fun ((id,l),ks) ->
      string_of_id id ^ "." ^ simple_string_of_loc l ^ ":" ^
        (String.concat "," (List.map (fun (kid,detail) ->
          string_of_kid kid ^ "." ^ string_of_match_detail detail)
                              (KBindings.bindings ks))))
       (ExtraSplits.bindings s))

let string_of_callerset s =
  String.concat ", " (List.map (fun (id,arg) -> string_of_id id ^ "." ^ string_of_int arg)
                        (CallerArgSet.elements s))

let string_of_callerkidset s =
  String.concat ", " (List.map (fun (id,kid) -> string_of_id id ^ "." ^ string_of_kid kid)
                        (CallerKidSet.elements s))

let string_of_dep = function
  | Have (args,extras) ->
     "Have (" ^ string_of_argsplits args ^ ";" ^ string_of_extra_splits extras ^ ")"
  | Unknown (l,msg) -> "Unknown " ^ msg ^ " at " ^ Reporting.loc_to_string l

(* If a callee uses a type variable as a size, does it need to be split in the
   current function, or is it also a parameter?  (Note that there may be multiple
   calls, so more than one parameter can be involved) *)
type call_dep =
  | InFun of dependencies
  | Parents of CallerKidSet.t

(* Result of analysing the body of a function.  The split field gives
   the arguments to split based on the body alone, the extra_splits
   field where we want to case split on a size type variable but
   there's no corresponding argument so we introduce a case
   expression, and the failures field where we couldn't do anything.
   The other fields are used at the end for the interprocedural
   phase. *)

type result = {
  split : arg_splits;
  extra_splits : extra_splits;
  failures : StringSet.t Failures.t;
  (* Dependencies for type variables of each fn called, so that
     if the fn uses one for a bitvector size we can track it back *)
  split_on_call : (call_dep KBindings.t) Bindings.t; (* kids per fn *)
  kid_in_caller : CallerKidSet.t
}

let empty = {
  split = ArgSplits.empty;
  extra_splits = ExtraSplits.empty;
  failures = Failures.empty;
  split_on_call = Bindings.empty;
  kid_in_caller = CallerKidSet.empty
}

let merge_detail _ x y =
  match x,y with
  | None, x -> x
  | x, None -> x
  | Some (Partial (ps1,l1)), Some (Partial (ps2,l2))
    when l1 = l2 && forall2 pat_eq ps1 ps2 -> x
  | _ -> Some Total

let opt_merge f _ x y =
  match x,y with
  | None, _ -> y
  | _, None -> x
  | Some x, Some y -> Some (f x y)

let merge_extras = ExtraSplits.merge (opt_merge (KBindings.merge merge_detail))

let dmerge x y =
  match x,y with
  | Unknown (l,s), _ -> Unknown (l,s)
  | _, Unknown (l,s) -> Unknown (l,s)
  | Have (args,extras), Have (args',extras') ->
     Have (ArgSplits.merge merge_detail args args',
           merge_extras extras extras')

let dempty = Have (ArgSplits.empty, ExtraSplits.empty)

let dep_bindings_merge a1 a2 =
  Bindings.merge (opt_merge dmerge) a1 a2

let dep_kbindings_merge a1 a2 =
  KBindings.merge (opt_merge dmerge) a1 a2

let call_kid_merge k x y =
  match x, y with
  | None, x -> x
  | x, None -> x
  | Some (InFun deps), Some (Parents _)
  | Some (Parents _), Some (InFun deps)
    -> Some (InFun deps)
  | Some (InFun deps), Some (InFun deps')
    -> Some (InFun (dmerge deps deps'))
  | Some (Parents fns), Some (Parents fns')
    -> Some (Parents (CallerKidSet.union fns fns'))

let call_arg_merge k args args' =
  match args, args' with
  | None, x -> x
  | x, None -> x
  | Some kdep, Some kdep'
    -> Some (KBindings.merge call_kid_merge kdep kdep')

let failure_merge _ x y =
  match x, y with
  | None, x -> x
  | x, None -> x
  | Some x, Some y -> Some (StringSet.union x y)

let merge rs rs' = {
  split = ArgSplits.merge merge_detail rs.split rs'.split;
  extra_splits = merge_extras rs.extra_splits rs'.extra_splits;
  failures = Failures.merge failure_merge rs.failures rs'.failures;
  split_on_call = Bindings.merge call_arg_merge rs.split_on_call rs'.split_on_call;
  kid_in_caller = CallerKidSet.union rs.kid_in_caller rs'.kid_in_caller
}

type env = {
  top_kids : kid list; (* Int kids bound by the function type *)
  var_deps : dependencies Bindings.t;
  kid_deps : dependencies KBindings.t;
  referenced_vars : IdSet.t;
  globals : bool Bindings.t (* is_value or not *)
}

let rec split3 = function
  | [] -> [],[],[]
  | ((h1,h2,h3)::t) ->
     let t1,t2,t3 = split3 t in
     (h1::t1,h2::t2,h3::t3)

let is_kid_in_env env kid =
  match Env.get_typ_var kid env with
  | _ -> true
  | exception _ -> false

let rec kids_bound_by_typ_pat (TP_aux (tp,_)) =
  match tp with
  | TP_wild -> KidSet.empty
  | TP_var kid -> KidSet.singleton kid
  | TP_app (_,pats) ->
     kidset_bigunion (List.map kids_bound_by_typ_pat pats)

(* We need both the explicitly bound kids from the AST, and any freshly
   generated kids from the typechecker. *)
let kids_bound_by_pat pat =
  let open Rewriter in
  fst (fold_pat ({ (compute_pat_alg KidSet.empty KidSet.union)
    with p_aux =
      (function ((s,(P_var (P_aux (_, annot'),tpat) as p)), annot) when not (is_empty_tannot (snd annot')) ->
        let kids = tyvars_of_typ (typ_of_annot annot') in
        let new_kids = KidSet.filter (fun kid -> not (is_kid_in_env (env_of_annot annot) kid)) kids in
        let tpat_kids = kids_bound_by_typ_pat tpat in
        KidSet.union s (KidSet.union new_kids tpat_kids), P_aux (p, annot)
      | ((s,p),ann) -> s, P_aux (p,ann))
    }) pat)

(* Diff the type environment to find new type variables and record that they
   depend on deps *)

let update_env_new_kids env deps typ_env_pre typ_env_post =
  let kbound =
    KBindings.merge (fun k x y ->
      match x,y with
      | Some k, None -> Some k
      | _ -> None)
      (Env.get_typ_vars typ_env_post)
      (Env.get_typ_vars typ_env_pre)
  in
  let kid_deps = KBindings.fold (fun v _ ds -> KBindings.add v deps ds) kbound env.kid_deps in
  { env with kid_deps = kid_deps }

(* Add bound variables from a pattern to the environment with the given dependency,
   plus any new type variables. *)

let update_env env deps pat typ_env_pre typ_env_post =
  let bound = Spec_analysis.bindings_from_pat pat in
  let var_deps = List.fold_left (fun ds v -> Bindings.add v deps ds) env.var_deps bound in
  update_env_new_kids { env with var_deps = var_deps } deps typ_env_pre typ_env_post

(* A function argument may end up with fresh type variables due to coercing
   unification (which will eventually be existentially bound in the type of
   the function).  Here we record the dependencies for these variables. *)

let add_arg_only_kids env typ_env typ deps =
  let all_vars = tyvars_of_typ typ in
  let check_kid kid kid_deps =
    if KBindings.mem kid kid_deps then kid_deps
    else KBindings.add kid deps kid_deps
  in
  let kid_deps = KidSet.fold check_kid all_vars env.kid_deps in
  { env with kid_deps }

let assigned_vars_exps es =
  List.fold_left (fun vs exp -> IdSet.union vs (Spec_analysis.assigned_vars exp))
    IdSet.empty es

(* For adding control dependencies to mutable variables *)

let add_dep_to_assigned dep assigns es =
  let assigned = assigned_vars_exps es in
  Bindings.mapi (fun id d -> if IdSet.mem id assigned then dmerge dep d else d) assigns

(* Functions to give dependencies for type variables in nexps, constraints, types and
   unification variables.  For function calls we also supply a list of dependencies for
   arguments so that we can find dependencies for existentially bound sizes. *)

let deps_of_tyvars l kid_deps arg_deps kids =
  let check kid deps =
    match KBindings.find kid kid_deps with
    | deps' -> dmerge deps deps'
    | exception Not_found ->
       match kid with
       | Kid_aux (Var kidstr, _) ->
          let unknown = Unknown (l, "Unknown type variable " ^ string_of_kid kid) in
          (* Tyvars from existentials in arguments have a special format *)
          if String.length kidstr > 5 && String.sub kidstr 0 4 = "'arg" then
            try
              let i = String.index kidstr '#' in
              let n = String.sub kidstr 4 (i-4) in
              let arg = int_of_string n in
              List.nth arg_deps arg
            with Not_found | Failure _ -> unknown
          else unknown
  in
  KidSet.fold check kids dempty

let deps_of_nexp l kid_deps arg_deps nexp =
  let kids = nexp_frees nexp in
  deps_of_tyvars l kid_deps arg_deps kids

let rec deps_of_nc kid_deps (NC_aux (nc,l)) =
  match nc with
  | NC_equal (nexp1,nexp2)
  | NC_bounded_ge (nexp1,nexp2)
  | NC_bounded_gt (nexp1,nexp2)
  | NC_bounded_le (nexp1,nexp2)
  | NC_bounded_lt (nexp1,nexp2)
  | NC_not_equal (nexp1,nexp2)
    -> dmerge (deps_of_nexp l kid_deps [] nexp1) (deps_of_nexp l kid_deps [] nexp2)
  | NC_set (kid,_) ->
     (match KBindings.find kid kid_deps with
     | deps -> deps
     | exception Not_found -> Unknown (l, "Unknown type variable in constraint " ^ string_of_kid kid))
  | NC_or (nc1,nc2)
  | NC_and (nc1,nc2)
    -> dmerge (deps_of_nc kid_deps nc1) (deps_of_nc kid_deps nc2)
  | NC_true
  | NC_false
    -> dempty
  | NC_app (Id_aux (Id "mod", _), [A_aux (A_nexp nexp1, _); A_aux (A_nexp nexp2, _)])
    -> dmerge (deps_of_nexp l kid_deps [] nexp1) (deps_of_nexp l kid_deps [] nexp2)
  | NC_var _ | NC_app _
    -> dempty

and deps_of_typ l kid_deps arg_deps typ =
  deps_of_tyvars l kid_deps arg_deps (tyvars_of_typ typ)

and deps_of_typ_arg l fn_id env arg_deps (A_aux (aux, _)) =
  match aux with
  | A_nexp (Nexp_aux (Nexp_var kid,_))
      when List.exists (fun k -> Kid.compare kid k == 0) env.top_kids ->
     Parents (CallerKidSet.singleton (fn_id,kid))
  | A_nexp nexp -> InFun (deps_of_nexp l env.kid_deps arg_deps nexp)
  | A_order _ -> InFun dempty
  | A_typ typ -> InFun (deps_of_typ l env.kid_deps arg_deps typ)
  | A_bool nc -> InFun (deps_of_nc env.kid_deps nc)

let mk_subrange_pattern vannot vstart vend =
  let (len,ord,typ) = vector_typ_args_of (Env.base_typ_of (env_of_annot vannot) (typ_of_annot vannot)) in
  match ord with
  | Ord_aux (Ord_var _,_) -> None
  | Ord_aux (ord',_) ->
     let vstart,vend = if ord' = Ord_inc then vstart,vend else vend,vstart
     in
     let dummyl = Generated Unknown in
     match len with
     | Nexp_aux (Nexp_constant len,_) -> 
        Some (fun pat ->
          let end_len = Big_int.pred (Big_int.sub len vend) in
          (* Wrap pat in its type; in particular the type checker won't
             manage P_wild in the middle of a P_vector_concat *)
          let pat = P_aux (P_typ (typ_of_pat pat, pat),(Generated (pat_loc pat),empty_tannot)) in
          let pats = if Big_int.greater end_len Big_int.zero then
              [pat;P_aux (P_typ (vector_typ (nconstant end_len) ord typ,
                                 P_aux (P_wild,(dummyl,empty_tannot))),(dummyl,empty_tannot))]
            else [pat]
          in
          let pats = if Big_int.greater vstart Big_int.zero then
              (P_aux (P_typ (vector_typ (nconstant vstart) ord typ,
                             P_aux (P_wild,(dummyl,empty_tannot))),(dummyl,empty_tannot)))::pats
            else pats
          in
          let pats = if ord' = Ord_inc then pats else List.rev pats
          in
          P_aux (P_vector_concat pats,(Generated (fst vannot),empty_tannot)))
     | _ -> None

(* If the expression matched on in a case expression is a function argument,
   and has no other dependencies, we can try to use the pattern match directly
   rather than doing a full case split. *)
let refine_dependency env (E_aux (e,(l,annot)) as exp) pexps =
  let check_dep id ctx =
    match Bindings.find id env.var_deps with
    | Have (args,extras) -> begin
      match ArgSplits.bindings args, ExtraSplits.bindings extras with
      | [(id',loc),Total], [] when Id.compare id id' == 0 ->
         (match Util.map_all (function
         | Pat_aux (Pat_exp (pat,_),_) -> Some (ctx pat)
         | Pat_aux (Pat_when (_,_,_),_) -> None) pexps
          with
          | Some pats ->
             if l = Parse_ast.Unknown then
               (Reporting.print_error
                  (Reporting.Err_general
                     (l, "No location for pattern match: " ^ string_of_exp exp));
                None)
             else
               Some (Have (ArgSplits.singleton (id,loc) (Partial (pats,l)),
                           ExtraSplits.empty))
          | None -> None)
      | _ -> None
    end
    | Unknown _ -> None
    | exception Not_found -> None
  in
  match e with
  | E_id id -> check_dep id (fun x -> x)
  | E_app (fn_id, [E_aux (E_id id,vannot);
                   E_aux (E_lit (L_aux (L_num vstart,_)),_);
                   E_aux (E_lit (L_aux (L_num vend,_)),_)])
      when is_id (env_of exp) (Id "vector_subrange") fn_id ->
     (match mk_subrange_pattern vannot vstart vend with
     | Some mk_pat -> check_dep id mk_pat
     | None -> None)
  | _ -> None

let simplify_size_nexp env typ_env (Nexp_aux (ne,l) as nexp) =
  match solve_unique typ_env nexp with
  | Some n -> nconstant n
  | None ->
     let is_equal kid =
       try
         prove __POS__ typ_env (NC_aux (NC_equal (Nexp_aux (Nexp_var kid,Unknown), nexp),Unknown))
       with _ -> false
     in
     match ne with
     | Nexp_var _
     | Nexp_constant _ -> nexp
     | _ ->
        match List.find is_equal env.top_kids with
        | kid -> Nexp_aux (Nexp_var kid, Generated l)
        | exception Not_found ->
           match KBindings.find_first_opt is_equal (Env.get_typ_vars typ_env) with
           | Some (kid,_) -> Nexp_aux (Nexp_var kid, Generated l)
           | None -> nexp

let simplify_size_typ_arg env typ_env = function
  | A_aux (A_nexp nexp, l) -> A_aux (A_nexp (simplify_size_nexp env typ_env nexp), l)
  | x -> x

(* Takes an environment of dependencies on vars, type vars, and flow control,
   and dependencies on mutable variables.  The latter are quite conservative,
   we currently drop variables assigned inside loops, for example. *)

let rec analyse_exp fn_id env assigns (E_aux (e,(l,annot)) as exp) =
  let remove_assigns es message =
    let assigned = assigned_vars_exps es in
    IdSet.fold
      (fun id asn ->
        Bindings.add id (Unknown (l, string_of_id id ^ message)) asn)
      assigned assigns
  in
  let non_det es =
    let assigns = remove_assigns es " assigned in non-deterministic expressions" in
    let deps, _, rs = split3 (List.map (analyse_exp fn_id env assigns) es) in
    (deps, assigns, List.fold_left merge empty rs)
  in
  (* We allow for arguments to functions being executed non-deterministically, but
     follow the type checker in processing them in-order to detect the automatic
     unpacking of existentials.  When we spot a new type variable (using
     update_env_new_kids) we set them to depend on the previous argument. *)
  let non_det_args es typs =
    let assigns = remove_assigns es " assigned in non-deterministic expressions" in
    let rec aux env = function
      | [], _ -> [], empty, env
      | (E_aux (_,ann) as h)::t, typ::typs ->
         let typ_env = env_of h in
         let new_deps, _, new_r = analyse_exp fn_id env assigns h in
         let env = add_arg_only_kids env typ_env typ new_deps in
         let t_deps, t_r, t_env = aux env (t,typs) in
         new_deps::t_deps, merge new_r t_r, t_env
    in
    let deps, r, env = aux env (es,typs) in
    (deps, assigns, r, env)
  in
  let merge_deps deps = List.fold_left dmerge dempty deps in
  let deps, assigns, r =
    match e with
    | E_block es ->
       let rec aux env assigns = function
         | [] -> (dempty, assigns, empty)
         | [e] -> analyse_exp fn_id env assigns e
         (* There's also a lone assignment case below where no env update is needed *)
         | E_aux (E_assign (lexp,e1),ann)::e2::es ->
            let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
            let assigns,r2 = analyse_lexp fn_id env assigns d1 lexp in
            let env = update_env_new_kids env d1 (env_of_annot ann) (env_of e2) in
            let d3, assigns, r3 = aux env assigns (e2::es) in
            (d3, assigns, merge (merge r1 r2) r3)
         | e::es ->
            let _, assigns, r' = analyse_exp fn_id env assigns e in
            let d, assigns, r = aux env assigns es in
            d, assigns, merge r r'
       in
       aux env assigns es
    | E_id id ->
       begin 
         match Bindings.find id env.var_deps with
         | args -> (args,assigns,empty)
         | exception Not_found ->
            match Bindings.find id assigns with
            | args -> (args,assigns,empty)
            | exception Not_found ->
               match Env.lookup_id id (Type_check.env_of_annot (l,annot)) with
               | Enum _ -> dempty,assigns,empty
               | Register _ -> Unknown (l, string_of_id id ^ " is a register"),assigns,empty
               | _ ->
                  if IdSet.mem id env.referenced_vars then
                    Unknown (l, string_of_id id ^ " may be modified via a reference"),assigns,empty
                  else match Bindings.find id env.globals with
                       | true -> dempty,assigns,empty (* value *)
                       | false -> Unknown (l, string_of_id id ^ " is a global but not a value"),assigns,empty
                       | exception Not_found ->
                          Unknown (l, string_of_id id ^ " is not in the environment"),assigns,empty
       end
    | E_lit _ -> (dempty,assigns,empty)
    | E_cast (_,e) -> analyse_exp fn_id env assigns e
    | E_app (id,args) ->
       let typ_env = env_of_annot (l,annot) in
       let (_,fn_typ) = Env.get_val_spec_orig id typ_env in
       let kid_inst = instantiation_of exp in
       let kid_inst = KBindings.fold (fun kid -> KBindings.add (orig_kid kid)) kid_inst KBindings.empty in
       let fn_typ = subst_unifiers kid_inst fn_typ in
       let arg_typs, fn_effect = match fn_typ with
         | Typ_aux (Typ_fn (args,_,eff),_) -> args,eff
         | _ -> [], Effect_aux (Effect_set [],Unknown)
       in
       (* We have to use the types from the val_spec here so that we can track
          any type variables that are generated by the coercing unification that
          the type checker applies after inferring the type of an argument, and
          that only appear in the unifiers. *)
       let deps, assigns, r, env = non_det_args args arg_typs in
       let eff_dep = match fn_effect with
         | Effect_aux (Effect_set ([] | [BE_aux (BE_undef,_)]),_) -> dempty
         | _ -> Unknown (l, "Effects from function application")
       in
       let kid_inst = KBindings.map (simplify_size_typ_arg env typ_env) kid_inst in
       (* Change kids in instantiation to the canonical ones from the type signature *)
       let kid_deps = KBindings.map (deps_of_typ_arg l fn_id env deps) kid_inst in
       let rdep,r' =
         if Id.compare fn_id id == 0 then
           let bad = Unknown (l,"Recursive call of " ^ string_of_id id) in
           let kid_deps = KBindings.map (fun _ -> InFun bad) kid_deps in
           bad, { empty with split_on_call = Bindings.singleton id kid_deps }
         else
           dempty, { empty with split_on_call = Bindings.singleton id kid_deps } in
       (merge_deps (rdep::eff_dep::deps), assigns, merge r r')
    | E_tuple es
    | E_list es ->
       let deps, assigns, r = non_det es in
       (merge_deps deps, assigns, r)
    | E_if (e1,e2,e3) ->
       let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
       let d2,a2,r2 = analyse_exp fn_id env assigns e2 in
       let d3,a3,r3 = analyse_exp fn_id env assigns e3 in
       let assigns = add_dep_to_assigned d1 (dep_bindings_merge a2 a3) [e2;e3] in
       (dmerge d1 (dmerge d2 d3), assigns, merge r1 (merge r2 r3))
    | E_loop (_,_,e1,e2) ->
       (* We remove all of the variables assigned in the loop, so we don't
          need to add control dependencies *)
       let assigns = remove_assigns [e1;e2] " assigned in a loop" in
       let d1,a1,r1 = analyse_exp fn_id env assigns e1 in
       let d2,a2,r2 = analyse_exp fn_id env assigns e2 in
     (dempty, assigns, merge r1 r2)
    | E_for (var,efrom,eto,eby,ord,body) ->
       let d1,assigns,r1 = non_det [efrom;eto;eby] in
       let assigns = remove_assigns [body] " assigned in a loop" in
       let d = merge_deps d1 in
       let loop_kid = mk_kid ("loop_" ^ string_of_id var) in
       let env' = { env with
         kid_deps = KBindings.add loop_kid d env.kid_deps} in
       let d2,a2,r2 = analyse_exp fn_id env' assigns body in
       (dempty, assigns, merge r1 r2)
    | E_vector es ->
       let ds, assigns, r = non_det es in
       (merge_deps ds, assigns, r)
    | E_vector_access (e1,e2)
    | E_vector_append (e1,e2)
    | E_cons (e1,e2) ->
       let ds, assigns, r = non_det [e1;e2] in
       (merge_deps ds, assigns, r)
    | E_vector_subrange (e1,e2,e3)
    | E_vector_update (e1,e2,e3) ->
       let ds, assigns, r = non_det [e1;e2;e3] in
       (merge_deps ds, assigns, r)
    | E_vector_update_subrange (e1,e2,e3,e4) ->
       let ds, assigns, r = non_det [e1;e2;e3;e4] in
       (merge_deps ds, assigns, r)
    | E_record fexps ->
       let es = List.map (function (FE_aux (FE_Fexp (_,e),_)) -> e) fexps in
       let ds, assigns, r = non_det es in
       (merge_deps ds, assigns, r)
    | E_record_update (e,fexps) ->
       let es = List.map (function (FE_aux (FE_Fexp (_,e),_)) -> e) fexps in
       let ds, assigns, r = non_det (e::es) in
       (merge_deps ds, assigns, r)
    | E_field (e,_) -> analyse_exp fn_id env assigns e
    | E_case (e,cases) ->
       let deps,assigns,r = analyse_exp fn_id env assigns e in
       let deps = match refine_dependency env e cases with
         | Some deps -> deps
         | None -> deps
       in
       let analyse_case (Pat_aux (pexp,_)) =
         match pexp with
         | Pat_exp (pat,e1) ->
            let env = update_env env deps pat (env_of_annot (l,annot)) (env_of e1) in
            let d,assigns,r = analyse_exp fn_id env assigns e1 in
            let assigns = add_dep_to_assigned deps assigns [e1] in
            (d,assigns,r)
         | Pat_when (pat,e1,e2) ->
            let env = update_env env deps pat (env_of_annot (l,annot)) (env_of e2) in
            let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
            let d2,assigns,r2 = analyse_exp fn_id env assigns e2 in
            let assigns = add_dep_to_assigned deps assigns [e1;e2] in
            (dmerge d1 d2, assigns, merge r1 r2)
       in
       let ds,assigns,rs = split3 (List.map analyse_case cases) in
       (merge_deps (deps::ds),
        List.fold_left dep_bindings_merge Bindings.empty assigns,
        List.fold_left merge r rs)
    | E_let (LB_aux (LB_val (pat,e1),_),e2) ->
       let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
       let env = update_env env d1 pat (env_of_annot (l,annot)) (env_of e2) in
       let d2,assigns,r2 = analyse_exp fn_id env assigns e2 in
       (d2,assigns,merge r1 r2)
    (* There's a more general assignment case above to update env inside a block. *)
    | E_assign (lexp,e1) ->
       let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
       let assigns,r2 = analyse_lexp fn_id env assigns d1 lexp in
       (dempty, assigns, merge r1 r2)
    | E_sizeof nexp ->
       (deps_of_nexp l env.kid_deps [] nexp, assigns, empty)
    | E_return e
    | E_exit e
    | E_throw e ->
       let _, _, r = analyse_exp fn_id env assigns e in
       (dempty, Bindings.empty, r)
    | E_ref id ->
       (Unknown (l, "May be mutated via reference to " ^ string_of_id id), assigns, empty)
    | E_try (e,cases) ->
       let deps,_,r = analyse_exp fn_id env assigns e in
       let assigns = remove_assigns [e] " assigned in try expression" in
       let analyse_handler (Pat_aux (pexp,_)) =
         match pexp with
         | Pat_exp (pat,e1) ->
            let env = update_env env (Unknown (l,"Exception")) pat (env_of_annot (l,annot)) (env_of e1) in
            let d,assigns,r = analyse_exp fn_id env assigns e1 in
            let assigns = add_dep_to_assigned deps assigns [e1] in
            (d,assigns,r)
         | Pat_when (pat,e1,e2) ->
            let env = update_env env (Unknown (l,"Exception")) pat (env_of_annot (l,annot)) (env_of e2) in
            let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
            let d2,assigns,r2 = analyse_exp fn_id env assigns e2 in
            let assigns = add_dep_to_assigned deps assigns [e1;e2] in
            (dmerge d1 d2, assigns, merge r1 r2)
       in
       let ds,assigns,rs = split3 (List.map analyse_handler cases) in
       (merge_deps (deps::ds),
        List.fold_left dep_bindings_merge Bindings.empty assigns,
        List.fold_left merge r rs)
    | E_assert (e1,_) -> analyse_exp fn_id env assigns e1

    | E_app_infix _
    | E_internal_plet _
    | E_internal_return _
    | E_internal_value _
      -> raise (Reporting.err_unreachable l __POS__
                  ("Unexpected expression encountered in monomorphisation: " ^ string_of_exp exp))

    | E_var (lexp,e1,e2) ->
       (* Really we ought to remove the assignment after e2 *)
       let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
       let assigns,r' = analyse_lexp fn_id env assigns d1 lexp in
       let d2,assigns,r2 = analyse_exp fn_id env assigns e2 in
       (dempty, assigns, merge r1 (merge r' r2))
    | E_constraint nc ->
       (deps_of_nc env.kid_deps nc, assigns, empty)
  in
  let deps =
    match destruct_atom_bool (env_of exp) (typ_of exp) with
    | Some nc -> dmerge deps (deps_of_nc env.kid_deps nc)
    | None -> deps
  in
  let r =
    (* Check for bitvector types with parametrised sizes *)
    match destruct_tannot annot with
    | None -> r
    | Some (tenv,typ,_) ->
       let typ = Env.base_typ_of tenv typ in
       let env, tenv, typ =
         match destruct_exist (Env.expand_synonyms tenv typ) with
         | None -> env, tenv, typ
         | Some (kopts, nc, typ) ->
            { env with kid_deps =
                List.fold_left (fun kds kopt -> KBindings.add (kopt_kid kopt) deps kds) env.kid_deps kopts },
           Env.add_constraint nc
             (List.fold_left (fun tenv kopt -> Env.add_typ_var l kopt tenv) tenv kopts),
           typ
       in
       let rec check_typ typ =
         if is_bitvector_typ typ then
           let size,_,_ = vector_typ_args_of typ in
           let Nexp_aux (size,_) as size_nexp = simplify_size_nexp env tenv size in
           let is_tyvar_parameter v =
             List.exists (fun k -> Kid.compare k v == 0) env.top_kids
           in
           match size with
           | Nexp_constant _ -> r
           | Nexp_var v when is_tyvar_parameter v ->
               { r with kid_in_caller = CallerKidSet.add (fn_id,v) r.kid_in_caller }
           | _ ->
               match deps_of_nexp l env.kid_deps [] size_nexp with
               | Have (args,extras) ->
                  { r with
                    split = ArgSplits.merge merge_detail r.split args;
                    extra_splits = merge_extras r.extra_splits extras
                  }
               | Unknown (l,msg) ->
                  { r with
                    failures =
                      Failures.add l (StringSet.singleton ("Unable to monomorphise " ^ string_of_nexp size_nexp ^ ": " ^ msg))
                        r.failures }
         else match typ with
              | Typ_aux (Typ_tup typs,_) ->
                 List.fold_left (fun r ty -> merge r (check_typ ty)) r typs
              | _ -> r
       in check_typ typ
  in (deps, assigns, r)


and analyse_lexp fn_id env assigns deps (LEXP_aux (lexp,(l,_))) =
 (* TODO: maybe subexps and sublexps should be non-det (and in const_prop_lexp, too?) *)
 match lexp with
  | LEXP_id id
  | LEXP_cast (_,id) ->
     if IdSet.mem id env.referenced_vars
     then assigns, empty
     else Bindings.add id deps assigns, empty
  | LEXP_memory (id,es) ->
     let _, assigns, r = analyse_exp fn_id env assigns (E_aux (E_tuple es,(Unknown,empty_tannot))) in
     assigns, r
  | LEXP_tup lexps
  | LEXP_vector_concat lexps ->
      List.fold_left (fun (assigns,r) lexp ->
       let assigns,r' = analyse_lexp fn_id env assigns deps lexp
       in assigns,merge r r') (assigns,empty) lexps
  | LEXP_vector (lexp,e) ->
     let _, assigns, r1 = analyse_exp fn_id env assigns e in
     let assigns, r2 = analyse_lexp fn_id env assigns deps lexp in
     assigns, merge r1 r2
  | LEXP_vector_range (lexp,e1,e2) ->
     let _, assigns, r1 = analyse_exp fn_id env assigns e1 in
     let _, assigns, r2 = analyse_exp fn_id env assigns e2 in
     let assigns, r3 = analyse_lexp fn_id env assigns deps lexp in
     assigns, merge r3 (merge r1 r2)
  | LEXP_field (lexp,_) -> analyse_lexp fn_id env assigns deps lexp
  | LEXP_deref e ->
     let _, assigns, r = analyse_exp fn_id env assigns e in
     assigns, r


let rec translate_loc l =
  match l with
  | Range (pos,_) -> Some (pos.Lexing.pos_fname,pos.Lexing.pos_lnum)
  | Generated l -> translate_loc l
  | _ -> None

let initial_env fn_id fn_l (TypQ_aux (tq,_)) pat body set_assertions globals =
  let pats = 
    match pat with
    | P_aux (P_tup pats,_) -> pats
    | _ -> [pat]
  in
  (* For the type in an annotation, produce the corresponding tyvar (if any),
     and a default case split (a set if there's one, a full case split if not). *)
  let kids_of_annot annot =
    let env = env_of_annot annot in
    let Typ_aux (typ,_) = Env.base_typ_of env (typ_of_annot annot) in
    match typ with
    | Typ_app (Id_aux (Id "atom",_),[A_aux (A_nexp (Nexp_aux (Nexp_var kid,_)),_)]) ->
       Spec_analysis.equal_kids env kid
    | _ -> KidSet.empty
  in
  let default_split annot kids =
    let kids = KidSet.elements kids in
    let try_kid kid = try Some (KBindings.find kid set_assertions) with Not_found -> None in
    match Util.option_first try_kid kids with
    | Some (l,is) ->
       let l' = Generated l in
       let pats = List.map (fun n -> P_aux (P_lit (L_aux (L_num n,l')),(l',annot))) is in
       let pats = pats @ [P_aux (P_wild,(l',annot))] in
       Partial (pats,l)
    | None -> Total
  in
  let qs =
    match tq with
    | TypQ_no_forall -> []
    | TypQ_tq qs -> qs
  in
  let eqn_instantiations = Type_check.instantiate_simple_equations qs in
  let eqn_kid_deps = KBindings.map (function
    | A_aux (A_nexp nexp, _) -> Some (nexp_frees nexp)
    | _ -> None) eqn_instantiations
  in
  let arg i pat =
    let rec aux (P_aux (p,(l,annot))) =
      let of_list pats =
        let ss,vs,ks = split3 (List.map aux pats) in
        let s = List.fold_left (ArgSplits.merge merge_detail) ArgSplits.empty ss in
        let v = List.fold_left dep_bindings_merge Bindings.empty vs in
        let k = List.fold_left dep_kbindings_merge KBindings.empty ks in
        s,v,k
      in
      match p with
      | P_lit _
      | P_wild
        -> ArgSplits.empty,Bindings.empty,KBindings.empty
      | P_or (p1, p2) ->
         let (s1, v1, k1) = aux p1 in
         let (s2, v2, k2) = aux p2 in
         (ArgSplits.merge merge_detail s1 s2, dep_bindings_merge v1 v2, dep_kbindings_merge k1 k2)
      | P_not p -> aux p
      | P_as (pat,id) ->
         begin
           let s,v,k = aux pat in
           match translate_loc (id_loc id) with
           | Some loc ->
              ArgSplits.add (id,loc) Total s,
              Bindings.add id (Have (ArgSplits.singleton (id,loc) Total, ExtraSplits.empty)) v,
              k
           | None ->
              s,
              Bindings.add id (Unknown (l, ("Unable to give location for " ^ string_of_id id))) v,
              k
         end
      | P_typ (_,pat) -> aux pat
      | P_id id ->
         begin
         match translate_loc (id_loc id) with
         | Some loc ->
            let kids = kids_of_annot (l,annot) in
            let split = default_split annot kids in
            let s = ArgSplits.singleton (id,loc) split in
            s,
            Bindings.singleton id (Have (s, ExtraSplits.empty)),
            KidSet.fold (fun kid k -> KBindings.add kid (Have (s, ExtraSplits.empty)) k) kids KBindings.empty
         | None ->
            ArgSplits.empty,
            Bindings.singleton id (Unknown (l, ("Unable to give location for " ^ string_of_id id))),
            KBindings.empty
         end
      | P_var (pat, tpat) ->
         let s,v,k = aux pat in
         let kids = kids_bound_by_typ_pat tpat in
         let kids = KidSet.fold (fun kid s ->
           KidSet.union s (Spec_analysis.equal_kids (env_of_annot (l,annot)) kid))
           kids kids in
         s,v,KidSet.fold (fun kid k -> KBindings.add kid (Have (s, ExtraSplits.empty)) k) kids k
      | P_app (_,pats) -> of_list pats
      | P_record (fpats,_) -> of_list (List.map (fun (FP_aux (FP_Fpat (_,p),_)) -> p) fpats)
      | P_vector pats
      | P_vector_concat pats
      | P_string_append pats
      | P_tup pats
      | P_list pats
        -> of_list pats
      | P_cons (p1,p2) -> of_list [p1;p2]
    in aux pat
  in
  let int_quant = function
    | QI_aux (QI_id (KOpt_aux (KOpt_kind (K_aux (K_int,_),kid),_)),_) -> Some kid
    | _ -> None
  in
  let top_kids = Util.map_filter int_quant qs in
  let _,var_deps,kid_deps = split3 (List.mapi arg pats) in
  let var_deps = List.fold_left dep_bindings_merge Bindings.empty var_deps in
  let kid_deps = List.fold_left dep_kbindings_merge KBindings.empty kid_deps in
  let note_no_arg kid_deps kid =
    if KBindings.mem kid kid_deps then kid_deps
    else
      (* When there's no argument to case split on for a kid, we'll add a
         case expression instead *)
      let env = env_of_pat pat in
      let split = default_split (mk_tannot env int_typ no_effect) (KidSet.singleton kid) in
      let extra_splits = ExtraSplits.singleton (fn_id, fn_l)
        (KBindings.singleton kid split) in
      KBindings.add kid (Have (ArgSplits.empty, extra_splits)) kid_deps
  in
  let kid_deps = List.fold_left note_no_arg kid_deps top_kids in
  let merge_kid_deps_eqns k kdeps eqn_kids =
    match kdeps, eqn_kids with
    | _, Some (Some kids) -> Some (KidSet.fold (fun kid deps -> dmerge deps (KBindings.find kid kid_deps)) kids dempty)
    | Some deps, _ -> Some deps
    | _, _ -> None
  in
  let kid_deps = KBindings.merge merge_kid_deps_eqns kid_deps eqn_kid_deps in
  let referenced_vars = Constant_propagation.referenced_vars body in
  { top_kids; var_deps; kid_deps; referenced_vars; globals }

(* When there's more than one pick the first *)
let merge_set_asserts _ x y =
  match x, y with
  | None, _ -> y
  | _, _ -> x
let merge_set_asserts_by_kid sets1 sets2 =
  KBindings.merge merge_set_asserts sets1 sets2

(* Set constraints in assertions don't always use the set syntax, so we also
   handle assert('N == 1 | ...) style set constraints *)
let rec sets_from_assert e =
  let set_from_or_exps (E_aux (_,(l,_)) as e) =
    let mykid = ref None in
    let check_kid kid =
      match !mykid with
      | None -> mykid := Some kid
      | Some kid' -> if Kid.compare kid kid' == 0 then ()
        else raise Not_found
    in
    let rec aux (E_aux (e,_)) =
      match e with
      | E_app (Id_aux (Id "or_bool",_),[e1;e2]) ->
         aux e1 @ aux e2
      | E_app (Id_aux (Id "eq_int",_),
               [E_aux (E_sizeof (Nexp_aux (Nexp_var kid,_)),_);
                E_aux (E_lit (L_aux (L_num i,_)),_)]) ->
         (check_kid kid; [i])
      (* TODO: Now that E_constraint is re-written by the typechecker,
         we'll end up with the following for the above - some of this
         function is probably redundant now *)
      | E_app (Id_aux (Id "eq_int",_),
               [E_aux (E_app (Id_aux (Id "__id", _), [E_aux (E_id id, annot)]), _);
                E_aux (E_lit (L_aux (L_num i,_)),_)]) ->
         begin match typ_of_annot annot with
         | Typ_aux (Typ_app (Id_aux (Id "atom", _), [A_aux (A_nexp (Nexp_aux (Nexp_var kid, _)), _)]), _) ->
            check_kid kid; [i]
         | _ -> raise Not_found
         end
      | _ -> raise Not_found
    in try
         let is = aux e in
         match !mykid with
         | None -> KBindings.empty
         | Some kid -> KBindings.singleton kid (l,is)
      with Not_found -> KBindings.empty
  in
  let rec set_from_nc_or (NC_aux (nc,_)) =
    match nc with
    | NC_equal (Nexp_aux (Nexp_var kid,_), Nexp_aux (Nexp_constant n,_)) ->
       Some (kid,[n])
    | NC_or (nc1, nc2) ->
       (match set_from_nc_or nc1, set_from_nc_or nc2 with
       | Some (kid1,l1), Some (kid2,l2) when Kid.compare kid1 kid2 == 0 -> Some (kid1,l1 @ l2)
       | _ -> None)
    | _ -> None
  in
  let rec sets_from_nc (NC_aux (nc,l) as nc_full) =
    match nc with
    | NC_and (nc1,nc2) -> merge_set_asserts_by_kid (sets_from_nc nc1) (sets_from_nc nc2)
    | NC_set (kid,is) -> KBindings.singleton kid (l,is)
    | NC_or _ ->
       (match set_from_nc_or nc_full with
       | Some (kid, is) -> KBindings.singleton kid (l,is)
       | None -> KBindings.empty)
    | _ -> KBindings.empty
  in
  match e with
  | E_aux (E_app (Id_aux (Id "and_bool",_),[e1;e2]),_) ->
     merge_set_asserts_by_kid (sets_from_assert e1) (sets_from_assert e2)
  | E_aux (E_constraint nc,_) -> sets_from_nc nc
  | _ -> set_from_or_exps e

(* Find all the easily reached set assertions in a function body, to use as
   case splits.  Note that this should be mirrored in stop_at_false_assertions,
   above. *)
let rec find_set_assertions (E_aux (e,_)) =
  match e with
  | E_block es ->
     List.fold_left merge_set_asserts_by_kid KBindings.empty (List.map find_set_assertions es)
  | E_cast (_,e) -> find_set_assertions e
  | E_let (LB_aux (LB_val (p,e1),_),e2) ->
     let sets1 = find_set_assertions e1 in
     let sets2 = find_set_assertions e2 in
     let kbound = kids_bound_by_pat p in
     let sets2 = KBindings.filter (fun kid _ -> not (KidSet.mem kid kbound)) sets2 in
     merge_set_asserts_by_kid sets1 sets2
  | E_assert (exp1,_) -> sets_from_assert exp1
  | _ -> KBindings.empty

let print_set_assertions set_assertions =
  if KBindings.is_empty set_assertions then
    print_endline "No top-level set assertions found."
  else begin
    print_endline "Top-level set assertions found:";
    KBindings.iter (fun k (l,is) ->
      print_endline (string_of_kid k ^ " @ " ^ simple_string_of_loc l ^ " " ^
                       String.concat "," (List.map Big_int.to_string is)))
      set_assertions
  end

let print_result r =
  let _ = print_endline ("  splits: " ^ string_of_argsplits r.split) in
  let print_kbinding kid dep =
    let s = match dep with
      | InFun dep -> "InFun " ^ string_of_dep dep
      | Parents cks -> string_of_callerkidset cks
    in
    let _ = print_endline ("      " ^ string_of_kid kid ^ ": " ^ s) in
    ()
  in
  let print_binding id kdep =
    let _ = print_endline ("    " ^ string_of_id id ^ ":") in
    let _ = KBindings.iter print_kbinding kdep in
    ()
  in
  let _ = print_endline "  split_on_call: " in
  let _ = Bindings.iter print_binding r.split_on_call in
  let _ = print_endline ("  kid_in_caller: " ^ string_of_callerkidset r.kid_in_caller) in
  let _ = print_endline ("  failures: \n    " ^
                            (String.concat "\n    "
                               (List.map (fun (l,s) -> Reporting.loc_to_string l ^ ":\n     " ^
                                 String.concat "\n      " (StringSet.elements s))
                                  (Failures.bindings r.failures)))) in
  ()

let analyse_funcl debug tenv constants (FCL_aux (FCL_Funcl (id,pexp),(l,_))) =
  let _ = if debug > 2 then print_endline (string_of_id id) else () in
  let pat,guard,body,_ = destruct_pexp pexp in
  let (tq,_) = Env.get_val_spec id tenv in
  let set_assertions = find_set_assertions body in
  let _ = if debug > 2 then print_set_assertions set_assertions in
  let aenv = initial_env id l tq pat body set_assertions constants in
  let _,_,r = analyse_exp id aenv Bindings.empty body in
  let r = match guard with
    | None -> r
    | Some exp -> let _,_,r' = analyse_exp id aenv Bindings.empty exp in
                  let r' =
                    if ExtraSplits.is_empty r'.extra_splits
                    then r'
                    else merge r' { empty with failures =
                        Failures.singleton l (StringSet.singleton
                                                "Case splitting size tyvars in guards not supported") }
                  in
                  merge r r'
  in
  let _ = if debug > 2 then print_result r else ()
  in r

let analyse_def debug env globals = function
  | DEF_fundef (FD_aux (FD_function (_,_,_,funcls),_)) ->
     globals, List.fold_left (fun r f -> merge r (analyse_funcl debug env globals f)) empty funcls

  | DEF_val (LB_aux (LB_val (P_aux ((P_id id | P_typ (_,P_aux (P_id id,_))),_), exp),_)) ->
     Bindings.add id (Constant_fold.is_constant exp) globals, empty

  | _ -> globals, empty

let detail_to_split = function
  | Total -> None
  | Partial (pats,l) -> Some (pats,l)

let argset_to_list splits =
  let l = ArgSplits.bindings splits in
  let argelt  = function
    | ((id,(file,loc)),detail) -> ((file,loc),string_of_id id,detail_to_split detail)
  in
  List.map argelt l

let analyse_defs debug env (Defs defs) =
  let def (globals,r) d =
    let globals,r' = analyse_def debug env globals d in
    globals, merge r r'
  in
  let _,r = List.fold_left def (Bindings.empty,empty) defs in

  (* Resolve the interprocedural dependencies *)

  let rec separate_deps = function
    | Have (splits, extras) ->
       splits, extras, Failures.empty
    | Unknown (l,msg) ->
       ArgSplits.empty, ExtraSplits.empty,
      Failures.singleton l (StringSet.singleton ("Unable to monomorphise dependency: " ^ msg))
  and chase_kid_caller (id,kid) =
    match Bindings.find id r.split_on_call with
    | kid_deps -> begin
      match KBindings.find kid kid_deps with
      | InFun deps -> separate_deps deps
      | Parents fns -> CallerKidSet.fold add_kid fns (ArgSplits.empty, ExtraSplits.empty, Failures.empty)
      | exception Not_found -> ArgSplits.empty,ExtraSplits.empty,Failures.empty
    end
    | exception Not_found -> ArgSplits.empty,ExtraSplits.empty,Failures.empty
  and add_kid k (splits,extras,fails) =
    let splits',extras',fails' = chase_kid_caller k in
    ArgSplits.merge merge_detail splits splits',
    merge_extras extras extras',
    Failures.merge failure_merge fails fails'
  in
  let _ = if debug > 1 then print_result r else () in
  let splits,extras,fails = CallerKidSet.fold add_kid r.kid_in_caller (r.split,r.extra_splits,r.failures) in
  let _ =
    if debug > 0 then
      (print_endline "Final splits:";
       print_endline (string_of_argsplits splits);
       print_endline (string_of_extra_splits extras))
    else ()
  in
  let splits = argset_to_list splits in
  if Failures.is_empty fails
  then (true,splits,extras) else
    begin
      Failures.iter (fun l msgs ->
        Reporting.print_err l "Monomorphisation" (String.concat "\n" (StringSet.elements msgs)))
        fails;
      (false, splits,extras)
    end

end

let fresh_sz_var =
  let counter = ref 0 in
  fun () ->
    let n = !counter in
    let () = counter := n+1 in
    mk_id ("sz#" ^ string_of_int n)

let add_extra_splits extras (Defs defs) =
  let success = ref true in
  let add_to_body extras (E_aux (_,(l,annot)) as e) =
    let l' = Generated l in
    KBindings.fold (fun kid detail (exp,split_list) ->
         let nexp = Nexp_aux (Nexp_var kid,l) in
         let var = fresh_sz_var () in
         let size_annot = mk_tannot (env_of e) (atom_typ nexp) no_effect in
         let loc = match Analysis.translate_loc l with
           | Some l -> l
           | None ->
              (Reporting.print_err l "Monomorphisation"
                 "Internal error: bad location for added case";
               ("",0))
         in
         let pexps = [Pat_aux (Pat_exp (P_aux (P_id var,(l,size_annot)),exp),(l',annot))] in
         E_aux (E_case (E_aux (E_sizeof nexp, (l',size_annot)), pexps),(l',annot)),
         ((loc, string_of_id var, Analysis.detail_to_split detail)::split_list)
    ) extras (e,[])
  in
  let add_to_funcl (FCL_aux (FCL_Funcl (id,Pat_aux (pexp,peannot)),(l,annot))) =
    let pexp, splits = 
      match Analysis.ExtraSplits.find (id,l) extras with
      | extras ->
         (match pexp with
         | Pat_exp (p,e) -> let e',sp = add_to_body extras e in Pat_exp (p,e'), sp
         | Pat_when (p,g,e) -> let e',sp = add_to_body extras e in Pat_when (p,g,e'), sp)
      | exception Not_found -> pexp, []
    in FCL_aux (FCL_Funcl (id,Pat_aux (pexp,peannot)),(l,annot)), splits
  in
  let add_to_def = function
    | DEF_fundef (FD_aux (FD_function (re,ta,ef,funcls),annot)) ->
       let funcls,splits = List.split (List.map add_to_funcl funcls) in
       DEF_fundef (FD_aux (FD_function (re,ta,ef,funcls),annot)), List.concat splits
    | d -> d, []
  in 
  let defs, splits = List.split (List.map add_to_def defs) in
  !success, Defs defs, List.concat splits

module MonoRewrites =
struct

let is_constant_range = function
  | E_aux (E_lit _,_), E_aux (E_lit _,_) -> true
  | _ -> false

let is_constant = function
  | E_aux (E_lit _,_) -> true
  | _ -> false

let is_constant_vec_typ env typ =
  let typ = Env.base_typ_of env typ in
  match destruct_vector env typ with
  | Some (size,_,_) ->
     (match nexp_simp size with
     | Nexp_aux (Nexp_constant _,_) -> true
     | _ -> false)
  | _ -> false

(* We have to add casts in here with appropriate length information so that the
   type checker knows the expected return types. *)

let rec rewrite_app env typ (id,args) =
  let is_append = is_id env (Id "append") in
  let is_subrange = is_id env (Id "vector_subrange") in
  let is_slice = is_id env (Id "slice") in
  let is_zeros id =
    is_id env (Id "Zeros") id || is_id env (Id "zeros") id ||
    is_id env (Id "sail_zeros") id
  in
  let is_ones id = is_id env (Id "Ones") id || is_id env (Id "ones") id ||
    is_id env (Id "sail_ones") id in
  let is_zero_extend =
    is_id env (Id "ZeroExtend") id ||
    is_id env (Id "zero_extend") id || is_id env (Id "sail_zero_extend") id ||
    is_id env (Id "mips_zero_extend") id || is_id env (Id "EXTZ") id
  in
  let is_truncate = is_id env (Id "truncate") id in
  let mk_exp e = E_aux (e, (Unknown, empty_tannot)) in
  let try_cast_to_typ (E_aux (e,(l, _)) as exp) =
    let (size,order,bittyp) = vector_typ_args_of (Env.base_typ_of env typ) in
    match size with
    | Nexp_aux (Nexp_constant _,_) -> E_cast (typ,exp)
    | _ -> match solve_unique env size with
      | Some c -> E_cast (vector_typ (nconstant c) order bittyp, exp)
      | None -> e
  in
  let rewrap e = E_aux (e, (Unknown, empty_tannot)) in
  if is_append id then
    match args with
      (* (known-size-vector @ variable-vector) @ variable-vector *)
    | [E_aux (E_app (append,
              [e1;
               E_aux (E_app (subrange1,
                             [vector1; start1; end1]),_)]),_);
       E_aux (E_app (subrange2,
                     [vector2; start2; end2]),_)]
        when is_append append && is_subrange subrange1 && is_subrange subrange2 &&
          is_constant_vec_typ env (typ_of e1) &&
          not (is_constant_range (start1, end1) || is_constant_range (start2, end2)) ->
       let (size,order,bittyp) = vector_typ_args_of (Env.base_typ_of env typ) in
       let (size1,_,_) = vector_typ_args_of (Env.base_typ_of env (typ_of e1)) in
       let midsize = nminus size size1 in begin
         match solve_unique env midsize with
         | Some c ->
            let midtyp = vector_typ (nconstant c) order bittyp in
            E_app (append,
                   [e1;
                    E_aux (E_cast (midtyp,
                                   E_aux (E_app (mk_id "subrange_subrange_concat",
                                                 [vector1; start1; end1; vector2; start2; end2]),
                                          (Unknown,empty_tannot))),(Unknown,empty_tannot))])
         | _ ->
            E_app (append,
                   [e1;
                    E_aux (E_app (mk_id "subrange_subrange_concat",
                                  [vector1; start1; end1; vector2; start2; end2]),
                           (Unknown,empty_tannot))])
       end
    | [E_aux (E_app (append,
              [e1;
               E_aux (E_app (slice1,
                             [vector1; start1; length1]),_)]),_);
       E_aux (E_app (slice2,
                     [vector2; start2; length2]),_)]
        when is_append append && is_slice slice1 && is_slice slice2 &&
          is_constant_vec_typ env (typ_of e1) &&
          not (is_constant length1 || is_constant length2) ->
       let (size,order,bittyp) = vector_typ_args_of (Env.base_typ_of env typ) in
       let (size1,_,_) = vector_typ_args_of (Env.base_typ_of env (typ_of e1)) in
       let midsize = nminus size size1 in begin
         match solve_unique env midsize with
         | Some c ->
            let midtyp = vector_typ (nconstant c) order bittyp in
            E_app (append,
                   [e1;
                    E_aux (E_cast (midtyp,
                                   E_aux (E_app (mk_id "slice_slice_concat",
                                                 [vector1; start1; length1; vector2; start2; length2]),
                                          (Unknown,empty_tannot))),(Unknown,empty_tannot))])
         | _ ->
            E_app (append,
                   [e1;
                    E_aux (E_app (mk_id "slice_slice_concat",
                                  [vector1; start1; length1; vector2; start2; length2]),
                           (Unknown,empty_tannot))])
       end

    (* variable-slice @ zeros *)
    | [E_aux (E_app (slice1, [vector1; start1; len1]),_);
       E_aux (E_app (zeros2, [len2]),_)]
        when is_slice slice1 && is_zeros zeros2 &&
          not (is_constant start1 && is_constant len1 && is_constant len2) ->
       try_cast_to_typ
         (mk_exp (E_app (mk_id "place_slice", [vector1; start1; len1; len2])))

    (* variable-range @ variable-range *)
    | [E_aux (E_app (subrange1,
                     [vector1; start1; end1]),_);
       E_aux (E_app (subrange2,
                     [vector2; start2; end2]),_)]
        when is_subrange subrange1 && is_subrange subrange2 &&
          not (is_constant_range (start1, end1) || is_constant_range (start2, end2)) ->
       try_cast_to_typ
         (E_aux (E_app (mk_id "subrange_subrange_concat",
                        [vector1; start1; end1; vector2; start2; end2]),
                 (Unknown,empty_tannot)))

    (* variable-slice @ variable-slice *)
    | [E_aux (E_app (slice1,
                     [vector1; start1; length1]),_);
       E_aux (E_app (slice2,
                     [vector2; start2; length2]),_)]
        when is_slice slice1 && is_slice slice2 &&
          not (is_constant length1 || is_constant length2) ->
       try_cast_to_typ
         (E_aux (E_app (mk_id "slice_slice_concat",
                        [vector1; start1; length1; vector2; start2; length2]),(Unknown,empty_tannot)))

    (* variable-slice @ local-var *)
    | [E_aux (E_app (slice1,
                     [vector1; start1; length1]),_);
       (E_aux (E_id _,_) as vector2)]
        when is_slice slice1 && not (is_constant length1) ->
       let start2 = mk_exp (E_lit (mk_lit (L_num Big_int.zero))) in
       let length2 = mk_exp (E_app (mk_id "length", [vector2])) in
       try_cast_to_typ
         (E_aux (E_app (mk_id "slice_slice_concat",
                        [vector1; start1; length1; vector2; start2; length2]),(Unknown,empty_tannot)))

    | [E_aux (E_app (append1,
                     [e1;
                      E_aux (E_app (slice1, [vector1; start1; length1]),_)]),_);
       E_aux (E_app (zeros1, [length2]),_)]
        when is_append append1 && is_slice slice1 && is_zeros zeros1 &&
          is_constant_vec_typ env (typ_of e1) &&
          not (is_constant length1 || is_constant length2) ->
       let (size,order,bittyp) = vector_typ_args_of (Env.base_typ_of env typ) in
       let (size1,_,_) = vector_typ_args_of (Env.base_typ_of env (typ_of e1)) in
       let midsize = nminus size size1 in begin
         match solve_unique env midsize with
         | Some c ->
            let midtyp = vector_typ (nconstant c) order bittyp in
            try_cast_to_typ
              (E_aux (E_app (mk_id "append",
                             [e1;
                              E_aux (E_cast (midtyp,
                                             E_aux (E_app (mk_id "slice_zeros_concat",
                                                           [vector1; start1; length1; length2]),(Unknown,empty_tannot))),(Unknown,empty_tannot))]),
                      (Unknown,empty_tannot)))
         | _ ->
            try_cast_to_typ
              (E_aux (E_app (mk_id "append",
                             [e1;
                              E_aux (E_app (mk_id "slice_zeros_concat",
                                            [vector1; start1; length1; length2]),(Unknown,empty_tannot))]),
                      (Unknown,empty_tannot)))
       end

    (* known-length @ (known-length @ var-length) *)
    | [e1; E_aux (E_app (append1, [e2; e3]), _)]
      when is_append append1 && is_constant_vec_typ env (typ_of e1) &&
           is_constant_vec_typ env (typ_of e2) &&
           not (is_constant_vec_typ env (typ_of e3)) ->
       let (size1,order,bittyp) = vector_typ_args_of (Env.base_typ_of env (typ_of e1)) in
       let (size2,_,_) = vector_typ_args_of (Env.base_typ_of env (typ_of e2)) in
       let size12 = nexp_simp (nsum size1 size2) in
       let tannot12 = mk_tannot env (vector_typ size12 order bittyp) no_effect in
       E_app (id, [E_aux (E_app (append1, [e1; e2]), (Unknown, tannot12)); e3])

    | _ -> E_app (id,args)

  else if is_id env (Id "eq_bits") id || is_id env (Id "neq_bits") id then
    (* variable-range == variable_range *)
    let wrap e =
      if is_id env (Id "neq_bits") id
      then E_app (mk_id "not_bool", [mk_exp e])
      else e
    in
    match args with
    | [E_aux (E_app (subrange1,
                     [vector1; start1; end1]),_);
       E_aux (E_app (subrange2,
                     [vector2; start2; end2]),_)]
        when is_subrange subrange1 && is_subrange subrange2 &&
          not (is_constant_range (start1, end1) || is_constant_range (start2, end2)) ->
       wrap (E_app (mk_id "subrange_subrange_eq",
              [vector1; start1; end1; vector2; start2; end2]))
    | [E_aux (E_app (slice1,
                     [vector1; len1; start1]),_);
       E_aux (E_app (slice2,
                     [vector2; len2; start2]),_)]
        when is_slice slice1 && is_slice slice2 &&
          not (is_constant len1 && is_constant start1 && is_constant len2 && is_constant start2) ->
       let upper start len =
         mk_exp (E_app_infix (start, mk_id "+",
                       mk_exp (E_app_infix (len, mk_id "-",
                                     mk_exp (E_lit (mk_lit (L_num (Big_int.of_int 1))))))))
       in
       wrap (E_app (mk_id "subrange_subrange_eq",
              [vector1; upper start1 len1; start1; vector2; upper start2 len2; start2]))
    | [E_aux (E_app (slice1, [vector1; start1; len1]), _);
       E_aux (E_app (zeros2, _), _)]
      when is_slice slice1 && is_zeros zeros2 && not (is_constant len1) ->
       wrap (E_app (mk_id "is_zeros_slice", [vector1; start1; len1]))
    | _ -> E_app (id,args)

  else if is_id env (Id "IsZero") id then
    match args with
    | [E_aux (E_app (subrange1, [vector1; start1; end1]),_)]
        when (is_id env (Id "vector_subrange") subrange1) &&
          not (is_constant_range (start1,end1)) ->
       E_app (mk_id "is_zero_subrange", [vector1; start1; end1])
    | [E_aux (E_app (slice1, [vector1; start1; len1]),_)]
        when (is_slice slice1) &&
          not (is_constant len1) ->
       E_app (mk_id "is_zeros_slice", [vector1; start1; len1])
    | _ -> E_app (id,args)

  else if is_id env (Id "IsOnes") id then
    match args with
    | [E_aux (E_app (subrange1, [vector1; start1; end1]),_)]
        when is_id env (Id "vector_subrange") subrange1 &&
          not (is_constant_range (start1,end1)) ->
       E_app (mk_id "is_ones_subrange",
              [vector1; start1; end1])
    | [E_aux (E_app (slice1, [vector1; start1; len1]),_)]
        when is_slice slice1 && not (is_constant len1) ->
       E_app (mk_id "is_ones_slice", [vector1; start1; len1])
    | _ -> E_app (id,args)

  else if is_zero_extend || is_truncate then
    let length_arg = List.filter (fun arg -> is_number (typ_of arg)) args in
    match List.filter (fun arg -> not (is_number (typ_of arg))) args with
    | [E_aux (E_app (append1,
                     [E_aux (E_app (subrange1, [vector1; start1; end1]), _);
                      (E_aux (E_app (zeros1, [len1]),_) |
                       E_aux (E_cast (_,E_aux (E_app (zeros1, [len1]),_)),_))
                ]),_)]
        when is_subrange subrange1 && is_zeros zeros1 && is_append append1
      -> try_cast_to_typ (rewrap (E_app (mk_id "place_subrange", length_arg @ [vector1; start1; end1; len1])))

    | [E_aux (E_app (append1,
                     [vector1;
                      (E_aux (E_app (zeros1, [length2]),_) |
                       E_aux (E_cast (_, E_aux (E_app (zeros1, [length2]),_)),_))
                ]),_)]
        when is_constant_vec_typ env (typ_of vector1) && is_zeros zeros1 && is_append append1
      -> let (vector1, start1, length1) =
           match vector1 with
           | E_aux (E_app (slice1, [vector1; start1; length1]), _) ->
              (vector1, start1, length1)
           | _ ->
              let (length1,_,_) = vector_typ_args_of (Env.base_typ_of env (typ_of vector1)) in
              (vector1, mk_exp (E_lit (mk_lit (L_num (Big_int.zero)))), mk_exp (E_sizeof length1))
         in
         try_cast_to_typ (rewrap (E_app (mk_id "place_slice", length_arg @ [vector1; start1; length1; length2])))

    (* If we've already rewritten to slice_slice_concat or subrange_subrange_concat,
       we can just drop the zero extension because those functions can do it
       themselves *)
    | [E_aux (E_cast (_, (E_aux (E_app (Id_aux ((Id "slice_slice_concat" | Id "subrange_subrange_concat" | Id "place_slice"),_) as op, args),_))),_)]
      -> try_cast_to_typ (rewrap (E_app (op, length_arg @ args)))

    | [E_aux (E_app (Id_aux ((Id "slice_slice_concat" | Id "subrange_subrange_concat" | Id "place_slice"),_) as op, args),_)]
      -> try_cast_to_typ (rewrap (E_app (op, length_arg @ args)))

    | [E_aux (E_app (slice1, [vector1; start1; length1]),_)]
        when is_slice slice1 && not (is_constant length1) ->
       try_cast_to_typ (rewrap (E_app (mk_id "zext_slice", length_arg @ [vector1; start1; length1])))

    | [E_aux (E_app (ones, [len1]),_)] when is_ones ones ->
       try_cast_to_typ (rewrap (E_app (mk_id "zext_ones", length_arg @ [len1])))

    | [E_aux (E_app (replicate_bits, [E_aux (E_lit (L_aux (L_bin "1", _)), _); len1]), _)]
        when is_id env (Id "replicate_bits") replicate_bits ->
       let start1 = mk_exp (E_lit (mk_lit (L_num Big_int.zero))) in
       try_cast_to_typ (rewrap (E_app (mk_id "slice_mask", length_arg @ [start1; len1])))

    | [E_aux (E_app (zeros, [len1]),_)]
    | [E_aux (E_cast (_, E_aux (E_app (zeros, [len1]),_)), _)]
      when is_zeros zeros ->
       try_cast_to_typ (rewrap (E_app (id, length_arg)))

    | _ -> E_app (id,args)

  else if is_id env (Id "SignExtend") id || is_id env (Id "sign_extend") id then
    let length_arg = List.filter (fun arg -> is_number (typ_of arg)) args in
    match List.filter (fun arg -> not (is_number (typ_of arg))) args with
    | [E_aux (E_app (slice1, [vector1; start1; length1]),_)]
        when is_slice slice1 && not (is_constant length1) ->
       try_cast_to_typ (rewrap (E_app (mk_id "sext_slice", length_arg @ [vector1; start1; length1])))

    | [E_aux (E_app (append,
         [E_aux (E_app (subrange1, [vector1; start1; end1]), _);
          (E_aux (E_app (zeros2, [len2]), _) |
           E_aux (E_cast (_, E_aux (E_app (zeros2, [len2]), _)),_))
                ]), _)]
      when is_append append && is_subrange subrange1 && is_zeros zeros2 &&
           not (is_constant len2) ->
       E_app (mk_id "place_subrange_signed", length_arg @ [vector1; start1; end1; len2])

    | [E_aux (E_app (append,
         [E_aux (E_app (slice1, [vector1; start1; len1]), _);
          (E_aux (E_app (zeros2, [len2]), _) |
           E_aux (E_cast (_, E_aux (E_app (zeros2, [len2]), _)),_))
                ]), _)]
      when is_append append && is_slice slice1 && is_zeros zeros2 &&
           not (is_constant len1 && is_constant len2) ->
       E_app (mk_id "place_slice_signed", length_arg @ [vector1; start1; len1; len2])

    | [E_aux (E_cast (_, (E_aux (E_app (Id_aux ((Id "place_slice"),_), args),_))),_)]
    | [E_aux (E_app (Id_aux ((Id "place_slice"),_), args),_)]
      -> try_cast_to_typ (rewrap (E_app (mk_id "place_slice_signed", length_arg @ args)))

      (* If the original had a length, keep it *)
    (* | [E_aux (E_app (slice1, [vector1; start1; length1]),_);length2]
        when is_slice slice1 && not (is_constant length1) ->
       begin
         match Type_check.destruct_atom_nexp (env_of length2) (typ_of length2) with
         | None -> E_app (mk_id "sext_slice", [vector1; start1; length1])
         | Some nlen ->
            let (_,order,bittyp) = vector_typ_args_of (Env.base_typ_of env typ) in
            E_cast (vector_typ nlen order bittyp,
                    E_aux (E_app (mk_id "sext_slice", [vector1; start1; length1]),
                           (Unknown,empty_tannot)))
       end *)

    | _ -> E_app (id,args)

  else if is_id env (Id "Extend") id then
    match args with
    | [vector; len; unsigned] ->
       let extz = mk_exp (rewrite_app env typ (mk_id "ZeroExtend", [vector; len])) in
       let exts = mk_exp (rewrite_app env typ (mk_id "SignExtend", [vector; len])) in
       E_if (unsigned, extz, exts)
    | _ -> E_app (id, args)

  else if is_id env (Id "UInt") id || is_id env (Id "unsigned") id then
    match args with
    | [E_aux (E_app (slice1, [vector1; start1; length1]),_)]
        when is_slice slice1 && not (is_constant length1) ->
       E_app (mk_id "unsigned_slice", [vector1; start1; length1])
    | [E_aux (E_app (subrange1, [vector1; start1; end1]),_)]
        when is_subrange subrange1 && not (is_constant_range (start1,end1)) ->
       E_app (mk_id "unsigned_subrange", [vector1; start1; end1])

    | _ -> E_app (id,args)

  else if is_id env (Id "__SetSlice_bits") id then
    match args with
    | [len; slice_len; vector; start; E_aux (E_app (zeros, _), _)]
      when is_zeros zeros ->
       E_app (mk_id "set_slice_zeros", [len; vector; start; slice_len])
    | _ -> E_app (id, args)

  else E_app (id,args)

let rewrite_aux = function
  | E_app (id,args), (l, tannot) ->
     begin match destruct_tannot tannot with
     | Some (env, ty, _) ->
        E_aux (rewrite_app env ty (id,args), (l, tannot))
     | None -> E_aux (E_app (id, args), (l, tannot))
     end
  | E_assign (
      LEXP_aux (LEXP_vector_range (LEXP_aux (LEXP_id id1,(l_id1,_)), start1, end1),_),
      E_aux (E_app (subrange2, [vector2; start2; end2]),(l_assign,_))),
    annot
       when is_id (env_of_annot annot) (Id "vector_subrange") subrange2 &&
              not (is_constant_range (start1, end1)) ->
     E_aux (E_assign (LEXP_aux (LEXP_id id1,(l_id1,empty_tannot)),
                      E_aux (E_app (mk_id "vector_update_subrange_from_subrange", [
                                   E_aux (E_id id1,(Generated l_id1,empty_tannot));
                                   start1; end1;
                                   vector2; start2; end2]),(Unknown,empty_tannot))),
            (l_assign, empty_tannot))
  | exp,annot -> E_aux (exp,annot)

let mono_rewrite defs =
  let open Rewriter in
  rewrite_defs_base
    { rewriters_base with
      rewrite_exp = fun _ -> fold_exp { id_exp_alg with e_aux = rewrite_aux } }
    defs
end

module BitvectorSizeCasts =
struct

let simplify_size_nexp env quant_kids nexp =
  let rec aux (Nexp_aux (ne,l) as nexp) =
    match solve_unique env nexp with
    | Some n -> Some (nconstant n)
    | None ->
       let is_equal kid =
         prove __POS__ env (NC_aux (NC_equal (Nexp_aux (Nexp_var kid,Unknown), nexp),Unknown))
       in
       match List.find is_equal quant_kids with
       | kid -> Some (Nexp_aux (Nexp_var kid,Generated l))
       | exception Not_found ->
          (* Normally rewriting of complex nexps in function signatures will
             produce a simple constant or variable above, but occasionally it's
             useful to work when that rewriting hasn't been applied.  In
             particular, that rewriting isn't fully working with RISC-V at the
             moment. *)
          let re f = function
            | Some n1, Some n2 -> Some (Nexp_aux (f n1 n2,l))
            | _ -> None
          in
          match ne with
          | Nexp_times(n1,n2) ->
             re (fun n1 n2 -> Nexp_times(n1,n2)) (aux n1, aux n2)
          | Nexp_sum(n1,n2) ->
             re (fun n1 n2 -> Nexp_sum(n1,n2)) (aux n1, aux n2)
          | Nexp_minus(n1,n2) ->
             re (fun n1 n2 -> Nexp_times(n1,n2)) (aux n1, aux n2)
          | Nexp_exp n ->
             Util.option_map (fun n -> Nexp_aux (Nexp_exp n,l)) (aux n)
          | Nexp_neg n ->
             Util.option_map (fun n -> Nexp_aux (Nexp_neg n,l)) (aux n)
          | _ -> None
  in aux nexp

let specs_required = ref IdSet.empty
let check_for_spec env name =
  let id = mk_id name in
  match Env.get_val_spec id env with
  | _ -> ()
  | exception _ -> specs_required := IdSet.add id !specs_required

(* These functions add cast functions across case splits, so that when a
   bitvector size becomes known in sail, the generated Lem code contains a
   function call to change mword 'n to (say) mword ty16, and vice versa. *)
let make_bitvector_cast_fns cast_name top_env env quant_kids src_typ target_typ =
  let genunk = Generated Unknown in
  let fresh =
    let counter = ref 0 in
    fun () ->
      let n = !counter in
      let () = counter := n+1 in
      mk_id ("cast#" ^ string_of_int n)
  in
  let at_least_one = ref None in
  let rec aux (Typ_aux (src_t,src_l) as src_typ) (Typ_aux (tar_t,tar_l) as tar_typ) =
    let src_ann = mk_tannot env src_typ no_effect in
    let tar_ann = mk_tannot env tar_typ no_effect in
    match src_t, tar_t with
    | Typ_tup typs, Typ_tup typs' ->
       let ps,es = List.split (List.map2 aux typs typs') in
       P_aux (P_typ (src_typ, P_aux (P_tup ps,(Generated src_l, src_ann))),(Generated src_l, src_ann)),
       E_aux (E_tuple es,(Generated tar_l, tar_ann))
    | Typ_app (Id_aux (Id "vector",_),
               [A_aux (A_nexp size,_); _;
                A_aux (A_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_)]),
      Typ_app (Id_aux (Id "vector",_) as t_id,
               [A_aux (A_nexp size',l_size'); t_ord;
                A_aux (A_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_) as t_bit]) -> begin
       match simplify_size_nexp env quant_kids size, simplify_size_nexp top_env quant_kids size' with
       | Some size, Some size' when Nexp.compare size size' <> 0 ->
          let var = fresh () in
          let tar_typ' = Typ_aux (Typ_app (t_id, [A_aux (A_nexp size',l_size');t_ord;t_bit]),
                                  tar_l) in
          let () = at_least_one := Some tar_typ' in
          P_aux (P_id var,(Generated src_l,src_ann)),
          E_aux
            (E_cast (tar_typ',
                     E_aux (E_app (Id_aux (Id cast_name, genunk),
                                   [E_aux (E_id var, (genunk, src_ann))]), (genunk, tar_ann))),
             (genunk, tar_ann))
       | _ ->
          let var = fresh () in
          P_aux (P_id var,(Generated src_l,src_ann)),
          E_aux (E_id var,(Generated src_l,tar_ann))
      end
    | _ ->
       let var = fresh () in
       P_aux (P_id var,(Generated src_l,src_ann)),
       E_aux (E_id var,(Generated src_l,tar_ann))
  in
  let src_typ' = Env.base_typ_of env src_typ in
  let target_typ' = Env.base_typ_of env target_typ in
  let pat, e' = aux src_typ' target_typ' in
  match !at_least_one with
  | Some one_target_typ -> begin
    check_for_spec env cast_name;
    let src_ann = mk_tannot env src_typ no_effect in
    let tar_ann = mk_tannot env target_typ no_effect in
    let asg_ann = mk_tannot env unit_typ no_effect in
    match src_typ' with
      (* Simple case with just the bitvector; don't need to pull apart value *)
    | Typ_aux (Typ_app _,_) ->
       (fun var exp ->
         let exp_ann = mk_tannot env (typ_of exp) (effect_of exp) in
         E_aux (E_let (LB_aux (LB_val (P_aux (P_typ (one_target_typ, P_aux (P_id var,(genunk,tar_ann))),(genunk,tar_ann)),
                                       E_aux (E_app (Id_aux (Id cast_name,genunk),
                                                     [E_aux (E_id var,(genunk,src_ann))]),(genunk,tar_ann))),(genunk,tar_ann)),
                       exp),(genunk,exp_ann))),
       (fun var ->
         [E_aux (E_assign (LEXP_aux (LEXP_cast (one_target_typ, var),(genunk,tar_ann)),
                          E_aux (E_app (Id_aux (Id cast_name,genunk),
                                        [E_aux (E_id var,(genunk,src_ann))]),(genunk,tar_ann)
                  )),(genunk,asg_ann))]),
      (fun (E_aux (_,(exp_l,exp_ann)) as exp) ->
        E_aux (E_cast (one_target_typ,
                       E_aux (E_app (Id_aux (Id cast_name, genunk), [exp]), (Generated exp_l,tar_ann))),

               (Generated exp_l,tar_ann)))
    | _ ->
       (fun var exp ->
         let exp_ann = mk_tannot env (typ_of exp) (effect_of exp) in
         E_aux (E_let (LB_aux (LB_val (pat, E_aux (E_id var,(genunk,src_ann))),(genunk,src_ann)),
                       E_aux (E_let (LB_aux (LB_val (P_aux (P_id var,(genunk,tar_ann)),e'),(genunk,tar_ann)),
                                     exp),(genunk,exp_ann))),(genunk,exp_ann))),
       (fun var ->
         [E_aux (E_let (LB_aux (LB_val (pat, E_aux (E_id var,(genunk,src_ann))),(genunk,src_ann)),
                       E_aux (E_assign (LEXP_aux (LEXP_cast (one_target_typ, var),(genunk,tar_ann)),
                                        e'),(genunk,asg_ann))),(genunk,asg_ann))]),
      (fun (E_aux (_,(exp_l,exp_ann)) as exp) ->
        E_aux (E_let (LB_aux (LB_val (pat, exp),(Generated exp_l,exp_ann)), e'),(Generated exp_l,tar_ann)))
  end
  | None -> (fun _ e -> e),(fun _ -> []),(fun e -> e)
let make_bitvector_cast_let cast_name top_env env quant_kids src_typ target_typ =
  let f,_,_ = make_bitvector_cast_fns cast_name top_env env quant_kids src_typ target_typ
  in f
let make_bitvector_cast_assign cast_name top_env env quant_kids src_typ target_typ =
  let _,f,_ = make_bitvector_cast_fns cast_name top_env env quant_kids src_typ target_typ
  in f
let make_bitvector_cast_cast cast_name top_env env quant_kids src_typ target_typ =
  let _,_,f = make_bitvector_cast_fns cast_name top_env env quant_kids src_typ target_typ
  in f

let ids_in_exp exp =
  let open Rewriter in
  fold_exp {
      (pure_exp_alg IdSet.empty IdSet.union) with
      e_id = IdSet.singleton;
      lEXP_id = IdSet.singleton;
      lEXP_memory = (fun (id,s) -> List.fold_left IdSet.union (IdSet.singleton id) s);
      lEXP_cast = (fun (_,id) -> IdSet.singleton id)
    } exp

let make_bitvector_env_casts env quant_kids (kid,i) exp =
  let mk_cast var typ exp = (make_bitvector_cast_let "bitvector_cast_in" env env quant_kids typ (subst_kids_typ (KBindings.singleton kid (nconstant i)) typ)) var exp in
  let mk_assign_in var typ =
    make_bitvector_cast_assign "bitvector_cast_in" env env quant_kids typ
      (subst_kids_typ (KBindings.singleton kid (nconstant i)) typ) var
  in
  let mk_assign_out var typ =
    make_bitvector_cast_assign "bitvector_cast_out" env env quant_kids
      (subst_kids_typ (KBindings.singleton kid (nconstant i)) typ) typ var
  in
  let locals = Env.get_locals env in
  let used_ids = ids_in_exp exp in
  let locals = Bindings.filter (fun id _ -> IdSet.mem id used_ids) locals in
  let immutables,mutables = Bindings.partition (fun _ (mut,_) -> mut = Immutable) locals in
  let assigns_in = Bindings.fold (fun var (_,typ) acc -> mk_assign_in var typ @ acc) mutables [] in
  let assigns_out = Bindings.fold (fun var (_,typ) acc -> mk_assign_out var typ @ acc) mutables [] in
  let exp = match assigns_in, exp with
    | [], _ -> exp
    | _::_, E_aux (E_block es,ann) -> E_aux (E_block (assigns_in @ es @ assigns_out),ann)
    | _::_, E_aux (_,(l,ann)) ->
       E_aux (E_block (assigns_in @ [exp] @ assigns_out), (Generated l,ann))
  in
  Bindings.fold (fun var (mut,typ) exp ->
    if mut = Immutable then mk_cast var typ exp else exp) immutables exp

let make_bitvector_cast_exp cast_name cast_env quant_kids typ target_typ exp =
  if alpha_equivalent cast_env typ target_typ then exp else
  let infer_arg_typ env f l typ =
    let (typq, ctor_typ) = Env.get_union_id f env in
    let quants = quant_items typq in
    match Env.expand_synonyms env ctor_typ with
    | Typ_aux (Typ_fn ([arg_typ], ret_typ, _), _) ->
       begin
           let goals = quant_kopts typq |> List.map kopt_kid |> KidSet.of_list in
           let unifiers = unify l env goals ret_typ typ in
           let arg_typ' = subst_unifiers unifiers arg_typ in
           arg_typ'
       end
    | _ -> typ_error env l ("Malformed constructor " ^ string_of_id f ^ " with type " ^ string_of_typ ctor_typ)

  in
  (* Push the cast down, including through constructors *)
  let rec aux exp (typ, target_typ) =
    if alpha_equivalent cast_env typ target_typ then exp else
    let exp_env = env_of exp in
    match exp with
    | E_aux (E_let (lb,exp'),ann) ->
       E_aux (E_let (lb,aux exp' (typ, target_typ)),ann)
    | E_aux (E_block exps,ann) ->
       let exps' = match List.rev exps with
         | [] -> []
         | final::l -> aux final (typ, target_typ)::l
       in E_aux (E_block (List.rev exps'),ann)
    | E_aux (E_tuple exps,(l,ann)) -> begin
       match Env.expand_synonyms exp_env typ, Env.expand_synonyms exp_env target_typ with
       | Typ_aux (Typ_tup src_typs,_), Typ_aux (Typ_tup tgt_typs,_) ->
          E_aux (E_tuple (List.map2 aux exps (List.combine src_typs tgt_typs)),(l,ann))
       | _ -> raise (Reporting.err_unreachable l __POS__
                ("Attempted to insert cast on tuple on non-tuple type: " ^
                   string_of_typ typ ^ " to " ^ string_of_typ target_typ))
      end
    | E_aux (E_app (f,args),(l,ann)) when Env.is_union_constructor f (env_of exp) ->
       let arg = match args with [arg] -> arg | _ -> E_aux (E_tuple args, (l,empty_tannot)) in
       let src_arg_typ = infer_arg_typ (env_of exp) f l typ in
       let tgt_arg_typ = infer_arg_typ (env_of exp) f l target_typ in
       E_aux (E_app (f,[aux arg (src_arg_typ, tgt_arg_typ)]),(l,ann))
    | _ ->
       (make_bitvector_cast_cast cast_name cast_env (env_of exp) quant_kids typ target_typ) exp
  in
  aux exp (typ, target_typ)

let rec extract_value_from_guard var (E_aux (e,_)) =
  match e with
  | E_app (op, ([E_aux (E_id var',_); E_aux (E_lit (L_aux (L_num i,_)),_)] |
                [E_aux (E_lit (L_aux (L_num i,_)),_); E_aux (E_id var',_)]))
      when string_of_id op = "eq_int" && Id.compare var var' == 0 ->
     Some i
  | E_app (op, [e1;e2]) when string_of_id op = "and_bool" ->
     (match extract_value_from_guard var e1 with
     | Some i -> Some i
     | None -> extract_value_from_guard var e2)
  | _ -> None

let fill_in_type env typ =
  let tyvars = tyvars_of_typ typ in
  let subst = KidSet.fold (fun kid subst ->
    match Env.get_typ_var kid env with
    | K_type
    | K_order
    | K_bool -> subst
    | K_int ->
       (match solve_unique env (nvar kid) with
       | None -> subst
       | Some n -> KBindings.add kid (nconstant n) subst)) tyvars KBindings.empty in
  subst_kids_typ subst typ

(* Extract the instantiations of kids resulting from an if or assert guard *)
let rec extract (E_aux (e,_)) =
  match e with
  | E_app (op,
           ([E_aux (E_sizeof (Nexp_aux (Nexp_var kid,_)),_); y] |
              [y; E_aux (E_sizeof (Nexp_aux (Nexp_var kid,_)),_)]))
       when string_of_id op = "eq_int" ->
     (match destruct_atom_nexp (env_of y) (typ_of y) with
      | Some (Nexp_aux (Nexp_constant i,_)) -> [(kid,i)]
      | _ -> [])
  | E_app (op,[x;y])
       when string_of_id op = "eq_int" ->
     (match destruct_atom_nexp (env_of x) (typ_of x), destruct_atom_nexp (env_of y) (typ_of y) with
      | Some (Nexp_aux (Nexp_var kid,_)), Some (Nexp_aux (Nexp_constant i,_))
        | Some (Nexp_aux (Nexp_constant i,_)), Some (Nexp_aux (Nexp_var kid,_))
        -> [(kid,i)]
      | _ -> [])
  | E_app (op, [x;y]) when string_of_id op = "and_bool" ->
     extract x @ extract y
  | _ -> []

(* TODO: top-level patterns *)
(* TODO: proper environment tracking for variables.  Currently we pretend that
   we can print the type of a variable in the top-level environment, but in
   practice they might be below a case split.  Note that we'd also need to
   provide some way for the Lem pretty printer to know what to use; currently
   we just use two names for the cast, bitvector_cast_in and bitvector_cast_out,
   to let the pretty printer know whether to use the top-level environment. *)
let add_bitvector_casts (Defs defs) =
  let rewrite_body id quant_kids top_env ret_typ exp =
    let rewrite_aux (e,ann) =
      match e with
      | E_case (E_aux (e',ann') as exp',cases) -> begin
        let env = env_of_annot ann in
        let result_typ = Env.base_typ_of env (typ_of_annot ann) in
        let matched_typ = Env.base_typ_of env (typ_of_annot ann') in
        match e',matched_typ with
        | E_sizeof (Nexp_aux (Nexp_var kid,_)), _
        | _, Typ_aux (Typ_app (Id_aux (Id "atom",_), [A_aux (A_nexp (Nexp_aux (Nexp_var kid,_)),_)]),_) ->
           let map_case pexp =
             let pat,guard,body,ann = destruct_pexp pexp in
             let body = match pat, guard with
               | P_aux (P_lit (L_aux (L_num i,_)),_), _ ->
                  (* We used to just substitute kid, but fill_in_type also catches other kids defined by it *)
                  let src_typ = fill_in_type (Env.add_constraint (nc_eq (nvar kid) (nconstant i)) env) result_typ in
                  make_bitvector_cast_exp "bitvector_cast_out" env quant_kids src_typ result_typ
                    (make_bitvector_env_casts env quant_kids (kid,i) body)
               | P_aux (P_id var,_), Some guard ->
                  (match extract_value_from_guard var guard with
                  | Some i ->
                     let src_typ = fill_in_type (Env.add_constraint (nc_eq (nvar kid) (nconstant i)) env) result_typ in
                     make_bitvector_cast_exp "bitvector_cast_out" env quant_kids src_typ result_typ
                       (make_bitvector_env_casts env quant_kids (kid,i) body)
                  | None -> body)
               | _ ->
                  body
             in
             construct_pexp (pat, guard, body, ann)
           in
           E_aux (E_case (exp', List.map map_case cases),ann)
        | _ -> E_aux (e,ann)
      end
      | E_if (e1,e2,e3) ->
         let env = env_of_annot ann in
         let result_typ = Env.base_typ_of env (typ_of_annot ann) in
         let insts = extract e1 in
         let e2' = List.fold_left (fun body inst ->
           make_bitvector_env_casts env quant_kids inst body) e2 insts in
         let insts = List.fold_left (fun insts (kid,i) ->
           KBindings.add kid (nconstant i) insts) KBindings.empty insts in
         let src_typ = subst_kids_typ insts result_typ in
         let e2' = make_bitvector_cast_exp "bitvector_cast_out" env quant_kids src_typ result_typ e2' in
         (* Ask the type checker if only one value remains for any of kids in
            the else branch. *)
         let env3 = env_of e3 in
         let insts3 = KBindings.fold (fun kid _ i3 ->
                          match Type_check.solve_unique env3 (nvar kid) with
                          | None -> i3
                          | Some c -> (kid, c)::i3)
                        insts []
         in
         let e3' = List.fold_left (fun body inst ->
           make_bitvector_env_casts env quant_kids inst body) e3 insts3 in
         let insts3 = List.fold_left (fun insts (kid,i) ->
           KBindings.add kid (nconstant i) insts) KBindings.empty insts3 in
         let src_typ3 = subst_kids_typ insts3 result_typ in
         let e3' = make_bitvector_cast_exp "bitvector_cast_out" env quant_kids src_typ3 result_typ e3' in
         E_aux (E_if (e1,e2',e3'), ann)
      | E_return e' ->
         E_aux (E_return (make_bitvector_cast_exp "bitvector_cast_out" top_env quant_kids (fill_in_type (env_of e') (typ_of e')) ret_typ e'),ann)
      | E_block es ->
         let env = env_of_annot ann in
         let result_typ = Env.base_typ_of env (typ_of_annot ann) in
         let rec aux = function
           | [] -> []
           | (E_aux (E_assert (assert_exp,msg),ann) as h)::t ->
              let insts = extract assert_exp in
              begin match insts with
              | [] -> h::(aux t)
              | _ ->
                 let t' = aux t in
                 let et = E_aux (E_block t',ann) in
                 let env = env_of h in
                 let et = List.fold_left (fun body inst ->
                              make_bitvector_env_casts env quant_kids inst body) et insts in
                 let insts = List.fold_left (fun insts (kid,i) ->
                                 KBindings.add kid (nconstant i) insts) KBindings.empty insts in
                 let src_typ = subst_kids_typ insts result_typ in
                 let et = make_bitvector_cast_exp "bitvector_cast_out" env quant_kids src_typ result_typ et in

                 [h; et]
              end
           | h::t -> h::(aux t)
         in E_aux (E_block (aux es),ann)
      | _ -> E_aux (e,ann)
    in
    let open Rewriter in
    fold_exp
      { id_exp_alg with
        e_aux = rewrite_aux } exp
  in
  let rewrite_funcl (FCL_aux (FCL_Funcl (id,pexp),((l,_) as fcl_ann))) =
    let fcl_env = env_of_annot fcl_ann in
    let (tq,typ) = Env.get_val_spec_orig id fcl_env in
    let fun_env = add_typquant l tq fcl_env in
    let quant_kids = List.map kopt_kid (List.filter is_int_kopt (quant_kopts tq)) in
    let ret_typ =
      match typ with
      | Typ_aux (Typ_fn (_,ret,_),_) -> ret
      | Typ_aux (_,l) as typ ->
         raise (Reporting.err_unreachable l __POS__
                  ("Function clause must have function type: " ^ string_of_typ typ ^
                      " is not a function type"))
    in
    let pat,guard,body,annot = destruct_pexp pexp in
    let body = rewrite_body id quant_kids fun_env ret_typ body in
    (* Also add a cast around the entire function clause body, if necessary *)
    let body =
      make_bitvector_cast_exp "bitvector_cast_out" fun_env quant_kids (fill_in_type (env_of body) (typ_of body)) ret_typ body
    in
    let pexp = construct_pexp (pat,guard,body,annot) in
    FCL_aux (FCL_Funcl (id,pexp),fcl_ann)
  in
  let rewrite_def = function
    | DEF_fundef (FD_aux (FD_function (r,t,e,fcls),fd_ann)) ->
       DEF_fundef (FD_aux (FD_function (r,t,e,List.map rewrite_funcl fcls),fd_ann))
    | d -> d
  in
  specs_required := IdSet.empty;
  let defs = List.map rewrite_def defs in
  let l = Generated Unknown in
  let Defs cast_specs,_ =
    (* TODO: use default/relevant order *)
    let kid = mk_kid "n" in
    let bitsn = vector_typ (nvar kid) dec_ord bit_typ in
    let ts = mk_typschm (mk_typquant [mk_qi_id K_int kid])
               (function_typ [bitsn] bitsn no_effect) in
    let mkfn name =
      mk_val_spec (VS_val_spec (ts,name,[("_", "zeroExtend")],false))
    in
    let defs = List.map mkfn (IdSet.elements !specs_required) in
    check initial_env (Defs defs)
  in Defs (cast_specs @ defs)
end

let replace_nexp_in_typ env typ orig new_nexp =
  let rec aux (Typ_aux (t,l) as typ) =
    match t with
    | Typ_id _
    | Typ_var _
        -> false, typ
    | Typ_fn (arg,res,eff) ->
       let arg' = List.map aux arg in
       let f1 = List.exists fst arg' in
       let f2, res = aux res in
       f1 || f2, Typ_aux (Typ_fn (List.map snd arg', res, eff),l)
    | Typ_bidir (t1, t2) ->
       let f1, t1 = aux t1 in
       let f2, t2 = aux t2 in
       f1 || f2, Typ_aux (Typ_bidir (t1, t2), l)
    | Typ_tup typs ->
       let fs, typs = List.split (List.map aux typs) in
       List.exists (fun x -> x) fs, Typ_aux (Typ_tup typs,l)
    | Typ_exist (kids,nc,typ') -> (* TODO avoid capture *)
       let f, typ' = aux typ' in
       f, Typ_aux (Typ_exist (kids,nc,typ'),l)
    | Typ_app (id, targs) ->
       let fs, targs = List.split (List.map aux_targ targs) in
       List.exists (fun x -> x) fs, Typ_aux (Typ_app (id, targs),l)
    | Typ_internal_unknown -> Reporting.unreachable l __POS__ "escaped Typ_internal_unknown"
  and aux_targ (A_aux (ta,l) as typ_arg) =
    match ta with
    | A_nexp nexp ->
       if prove __POS__ env (nc_eq nexp orig)
       then true, A_aux (A_nexp new_nexp,l)
       else false, typ_arg
    | A_typ typ ->
       let f, typ = aux typ in
       f, A_aux (A_typ typ,l)
    | A_order _
    | A_bool _
      -> false, typ_arg
  in aux typ

let fresh_nexp_kid nexp =
  let rec mangle_nexp (Nexp_aux (nexp, _)) =
    match nexp with
    | Nexp_id id -> string_of_id id
    | Nexp_var kid -> string_of_id (id_of_kid kid)
    | Nexp_constant i ->
       (if Big_int.greater_equal i Big_int.zero then "p" else "m")
       ^ Big_int.to_string (Big_int.abs i)
    | Nexp_times (n1, n2) -> mangle_nexp n1 ^ "_times_" ^ mangle_nexp n2
    | Nexp_sum (n1, n2) -> mangle_nexp n1 ^ "_plus_" ^ mangle_nexp n2
    | Nexp_minus (n1, n2) -> mangle_nexp n1 ^ "_minus_" ^ mangle_nexp n2
    | Nexp_exp n -> "exp_" ^ mangle_nexp n
    | Nexp_neg n -> "neg_" ^ mangle_nexp n
    | Nexp_app (id,args) -> string_of_id id ^ "_" ^
       String.concat "_" (List.map mangle_nexp args)
  in
  (* TODO: I'd like to add a # to distinguish it from user-provided names, but
     the rewriter currently uses them as a hint that they're not printable in
     types, which these are explicitly supposed to be. *)
  mk_kid (mangle_nexp nexp (*^ "#"*))

let rewrite_toplevel_nexps (Defs defs) =
  let find_nexp env nexp_map nexp =
    let is_equal (kid,nexp') = prove __POS__ env (nc_eq nexp nexp') in
    List.find is_equal nexp_map
  in
  let rec rewrite_typ_in_spec env nexp_map (Typ_aux (t,ann) as typ_full) =
    match t with
    | Typ_fn (args,res,eff) ->
       let args' = List.map (rewrite_typ_in_spec env nexp_map) args in
       let nexp_map = List.concat (List.map fst args') in
       let nexp_map, res = rewrite_typ_in_spec env nexp_map res in
       nexp_map, Typ_aux (Typ_fn (List.map snd args',res,eff),ann)
    | Typ_tup typs ->
       let nexp_map, typs =
         List.fold_right (fun typ (nexp_map,t) ->
           let nexp_map, typ = rewrite_typ_in_spec env nexp_map typ in
           (nexp_map, typ::t)) typs (nexp_map,[])
       in nexp_map, Typ_aux (Typ_tup typs,ann)
    | _ when is_number typ_full || is_bitvector_typ typ_full -> begin
       let nexp_opt =
         match destruct_atom_nexp env typ_full with
         | Some nexp -> Some nexp
         | None ->
            if is_bitvector_typ typ_full then
              let (size,_,_) = vector_typ_args_of typ_full in
              Some size
            else None
       in match nexp_opt with
       | None -> nexp_map, typ_full
       | Some (Nexp_aux (Nexp_constant _,_))
       | Some (Nexp_aux (Nexp_var _,_)) -> nexp_map, typ_full
       | Some nexp ->
          let nexp_map, kid =
            match find_nexp env nexp_map nexp with
            | (kid,_) -> nexp_map, kid
            | exception Not_found ->
               let kid = fresh_nexp_kid nexp in
               (kid, nexp)::nexp_map, kid
          in
          let new_nexp = nvar kid in
          nexp_map, snd (replace_nexp_in_typ env typ_full nexp new_nexp)
      end
    | _ ->
       let typ' = Env.base_typ_of env typ_full in
       if Typ.compare typ_full typ' == 0 then
         match t with
         | Typ_app (f,args) ->
            let in_arg nexp_map (A_aux (arg,l) as arg_full) =
              match arg with
              | A_typ typ ->
                 let nexp_map, typ' = rewrite_typ_in_spec env nexp_map typ in
                 nexp_map, A_aux (A_typ typ',l)
              | A_bool _ | A_nexp _ | A_order _ -> nexp_map, arg_full
            in
            let nexp_map, args =
              List.fold_right (fun arg (nexp_map,args) ->
                  let nexp_map, arg = in_arg nexp_map arg in
                  (nexp_map, arg::args)) args (nexp_map,[])
            in nexp_map, Typ_aux (Typ_app (f,args),ann)
         | _ -> nexp_map, typ_full
       else rewrite_typ_in_spec env nexp_map typ'
  in
  let rewrite_valspec (VS_aux (VS_val_spec (TypSchm_aux (TypSchm_ts (tqs,typ),ts_l),id,ext_opt,is_cast),ann)) =
    match tqs with
    | TypQ_aux (TypQ_no_forall,_) -> None
    | TypQ_aux (TypQ_tq qs, tq_l) ->
       let env = env_of_annot ann in
       let env = add_typquant tq_l tqs env in
       let nexp_map, typ = rewrite_typ_in_spec env [] typ in
       match nexp_map with
       | [] -> None
       | _ ->
          let new_vars = List.map (fun (kid,nexp) -> QI_aux (QI_id (mk_kopt K_int kid), Generated tq_l)) nexp_map in
          let new_constraints = List.map (fun (kid,nexp) -> QI_aux (QI_constraint (nc_eq (nvar kid) nexp), Generated tq_l)) nexp_map in
          let tqs = TypQ_aux (TypQ_tq (qs @ new_vars @ new_constraints),tq_l) in
          let vs =
            VS_aux (VS_val_spec (TypSchm_aux (TypSchm_ts (tqs,typ),ts_l),id,ext_opt,is_cast),ann) in
          Some (id, nexp_map, vs)
  in
  (* Changing types in the body confuses simple sizeof rewriting, so turn it
     off for now *)
  let rewrite_typ_in_body env nexp_map typ =
    let rec aux (Typ_aux (t,l) as typ_full) =
    match t with
    | Typ_tup typs -> Typ_aux (Typ_tup (List.map aux typs),l)
    | Typ_exist (kids,nc,typ') -> (* TODO: avoid shadowing *)
       Typ_aux (Typ_exist (kids,(* TODO? *) nc, aux typ'),l)
    | Typ_app (id,targs) -> Typ_aux (Typ_app (id,List.map aux_targ targs),l)
    | _ -> typ_full
    and aux_targ (A_aux (ta,l) as ta_full) =
      match ta with
      | A_typ typ -> A_aux (A_typ (aux typ),l)
      | A_order _ -> ta_full
      | A_nexp nexp -> A_aux (A_nexp (aux_nexp nexp), l)
      | A_bool nc -> A_aux (A_bool (aux_nconstraint nc), l)
    and aux_nexp nexp =
      match find_nexp env nexp_map nexp with
      | (kid,_) -> nvar kid
      | exception Not_found -> nexp
    and aux_nconstraint (NC_aux (nc, l)) =
      let rewrap nc = NC_aux (nc, l) in
      match nc with
      | NC_equal (n1, n2) -> rewrap (NC_equal (aux_nexp n1, aux_nexp n2))
      | NC_bounded_ge (n1, n2) -> rewrap (NC_bounded_ge (aux_nexp n1, aux_nexp n2))
      | NC_bounded_gt (n1, n2) -> rewrap (NC_bounded_gt (aux_nexp n1, aux_nexp n2))
      | NC_bounded_le (n1, n2) -> rewrap (NC_bounded_le (aux_nexp n1, aux_nexp n2))
      | NC_bounded_lt (n1, n2) -> rewrap (NC_bounded_lt (aux_nexp n1, aux_nexp n2))
      | NC_not_equal (n1, n2) -> rewrap (NC_not_equal (aux_nexp n1, aux_nexp n2))
      | NC_or (nc1, nc2) -> rewrap (NC_or (aux_nconstraint nc1, aux_nconstraint nc2))
      | NC_and (nc1, nc2) -> rewrap (NC_and (aux_nconstraint nc1, aux_nconstraint nc2))
      | NC_app (id, args) -> rewrap (NC_app (id, List.map aux_targ args))
      | _ -> rewrap nc
    in aux typ
  in
  let rewrite_one_exp nexp_map (e,ann) =
    match e with
    | E_cast (typ,e') -> E_aux (E_cast (rewrite_typ_in_body (env_of_annot ann) nexp_map typ,e'),ann)
    | E_sizeof nexp ->
       (match find_nexp (env_of_annot ann) nexp_map nexp with
       | (kid,_) -> E_aux (E_sizeof (nvar kid),ann)
       | exception Not_found -> E_aux (e,ann))
    | _ -> E_aux (e,ann)
  in
  let rewrite_one_pat nexp_map (p,ann) =
    match p with
    | P_typ (typ,p') -> P_aux (P_typ (rewrite_typ_in_body (env_of_annot ann) nexp_map typ,p'),ann)
    | _ -> P_aux (p,ann)
  in
  let rewrite_one_lexp nexp_map (lexp, ann) =
    match lexp with
    | LEXP_cast (typ, id) ->
       LEXP_aux (LEXP_cast (rewrite_typ_in_body (env_of_annot ann) nexp_map typ, id), ann)
    | _ -> LEXP_aux (lexp, ann)
  in
  let rewrite_body nexp_map pexp =
    let open Rewriter in
    fold_pexp { id_exp_alg with
      e_aux = rewrite_one_exp nexp_map;
      lEXP_aux = rewrite_one_lexp nexp_map;
      pat_alg = { id_pat_alg with p_aux = rewrite_one_pat nexp_map }
    } pexp
  in
  let rewrite_funcl spec_map (FCL_aux (FCL_Funcl (id,pexp),ann) as funcl) =
    match Bindings.find id spec_map with
    | nexp_map -> FCL_aux (FCL_Funcl (id,rewrite_body nexp_map pexp),ann)
    | exception Not_found -> funcl
  in
  let rewrite_def spec_map def =
    match def with
    | DEF_spec vs -> (match rewrite_valspec vs with
      | None -> spec_map, def
      | Some (id, nexp_map, vs) -> Bindings.add id nexp_map spec_map, DEF_spec vs)
    | DEF_fundef (FD_aux (FD_function (recopt,_,eff,funcls),ann)) ->
       (* Type annotations on function definitions will have been turned into
          valspecs by type checking, so it should be safe to drop them rather
          than updating them. *)
       let tann = Typ_annot_opt_aux (Typ_annot_opt_none,Generated Unknown) in
       spec_map,
       DEF_fundef (FD_aux (FD_function (recopt,tann,eff,List.map (rewrite_funcl spec_map) funcls),ann))
    | _ -> spec_map, def
  in
  let _, defs = List.fold_left (fun (spec_map,t) def ->
    let spec_map, def = rewrite_def spec_map def in
    (spec_map, def::t)) (Bindings.empty, []) defs
  in
  (* Allow use of div and mod in nexp rewriting during later typechecking passes
     to help prove equivalences such as (8 * 'n) = 'p8_times_n# *)
  Type_check.opt_smt_div := true;
  Defs (List.rev defs)

type options = {
  auto : bool;
  debug_analysis : int;
  all_split_errors : bool;
  continue_anyway : bool
}

let recheck defs =
  let w = !Reporting.opt_warnings in
  let () = Reporting.opt_warnings := false in
  let r = Type_error.check (Type_check.Env.no_casts Type_check.initial_env) defs in
  let () = Reporting.opt_warnings := w in
  r

let mono_rewrites = MonoRewrites.mono_rewrite

let monomorphise opts splits defs =
  let defs, env = Type_check.check Type_check.initial_env defs in
  let ok_analysis, new_splits, extra_splits =
    if opts.auto
    then
      let f,r,ex = Analysis.analyse_defs opts.debug_analysis env defs in
      if f || opts.all_split_errors || opts.continue_anyway
      then f, r, ex
      else raise (Reporting.err_general Unknown "Unable to monomorphise program")
    else true, [], Analysis.ExtraSplits.empty in
  let splits = new_splits @ (List.map (fun (loc,id) -> (loc,id,None)) splits) in
  let ok_extras, defs, extra_splits = add_extra_splits extra_splits defs in
  let splits = splits @ extra_splits in
  let () = if ok_extras || opts.all_split_errors || opts.continue_anyway
      then ()
      else raise (Reporting.err_general Unknown "Unable to monomorphise program")
  in
  let ok_split, defs = split_defs opts.all_split_errors splits env defs in
  let () = if (ok_analysis && ok_extras && ok_split) || opts.continue_anyway
      then ()
      else raise (Reporting.err_general Unknown "Unable to monomorphise program")
  in defs

let add_bitvector_casts = BitvectorSizeCasts.add_bitvector_casts
let rewrite_atoms_to_singletons defs =
  let defs, env = Type_check.check Type_check.initial_env defs in
  AtomToItself.rewrite_size_parameters env defs
