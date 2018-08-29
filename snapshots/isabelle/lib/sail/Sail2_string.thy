chapter \<open>Generated by Lem from \<open>../../src/gen_lib/sail2_string.lem\<close>.\<close>

theory "Sail2_string" 

imports
  Main
  "LEM.Lem_pervasives"
  "LEM.Lem_list"
  "LEM.Lem_list_extra"
  "LEM.Lem_string"
  "LEM.Lem_string_extra"
  "Sail2_operators"
  "Sail2_values"

begin 

(*open import Pervasives*)
(*open import List*)
(*open import List_extra*)
(*open import String*)
(*open import String_extra*)

(*open import Sail2_operators*)
(*open import Sail2_values*)

(*val string_sub : string -> ii -> ii -> string*)
definition string_sub  :: " string \<Rightarrow> int \<Rightarrow> int \<Rightarrow> string "  where 
     " string_sub str start len = (
  (List.take (nat (abs ( len))) (List.drop (nat (abs ( start))) ( str))))"


(*val string_startswith : string -> string -> bool*)
definition string_startswith  :: " string \<Rightarrow> string \<Rightarrow> bool "  where 
     " string_startswith str1 str2 = (
  (let prefix = (string_sub str1(( 0 :: int)) (int (List.length str2))) in
  (prefix = str2)))"


(*val string_drop : string -> ii -> string*)
definition string_drop  :: " string \<Rightarrow> int \<Rightarrow> string "  where 
     " string_drop str n = (
  (List.drop (nat (abs ( n))) ( str)))"


(*val string_length : string -> ii*)
definition string_length  :: " string \<Rightarrow> int "  where 
     " string_length s = ( int (List.length s))"


definition string_append  :: " string \<Rightarrow> string \<Rightarrow> string "  where 
     " string_append = ( (@))"


(***********************************************
 * Begin stuff that should be in Lem Num_extra *
 ***********************************************)

(*val maybeIntegerOfString : string -> maybe integer*)
definition maybeIntegerOfString  :: " string \<Rightarrow>(int)option "  where 
     " maybeIntegerOfString _ = ( None )"


(***********************************************
 * end stuff that should be in Lem Num_extra   *
 ***********************************************)

function (sequential,domintros)  maybe_int_of_prefix  :: " string \<Rightarrow>(int*int)option "  where 
     " maybe_int_of_prefix s = ( 
  if(s = ('''')) then None else
    ((let len = (string_length s) in
     (case  maybeIntegerOfString s of
           Some n => Some (n, len)
       | None => maybe_int_of_prefix
                   (string_sub s (( 0 :: int)) (len - ( 1 :: int)))
     ))) )" 
by pat_completeness auto


definition maybe_int_of_string  :: " string \<Rightarrow>(int)option "  where 
     " maybe_int_of_string = ( maybeIntegerOfString )"


(*val n_leading_spaces : string -> ii*)
function (sequential,domintros)  n_leading_spaces  :: " string \<Rightarrow> int "  where 
     " n_leading_spaces s = (
  (let len = (string_length s) in
  if len =( 0 :: int) then( 0 :: int) else
    if len =( 1 :: int) then  
  if(s = ('' '')) then ( 1 :: int) else ( 0 :: int)
    else
      (* match len with
   *     (* | 0 -> 0 *)
   * (* | 1 -> *) 
   * | len -> *)
           (* Isabelle generation for pattern matching on characters
              is currently broken, so use an if-expression *)
           if nth s(( 0 :: nat)) = (CHR '' '')
           then( 1 :: int) + (n_leading_spaces (string_sub s(( 1 :: int)) (len -( 1 :: int))))
           else( 0 :: int)))" 
by pat_completeness auto

  (* end *)

definition opt_spc_matches_prefix  :: " string \<Rightarrow>(unit*int)option "  where 
     " opt_spc_matches_prefix s = (
  Some (() , n_leading_spaces s))"


definition spc_matches_prefix  :: " string \<Rightarrow>(unit*int)option "  where 
     " spc_matches_prefix s = (
  (let n = (n_leading_spaces s) in
  (* match n with *)
(* | 0 -> Nothing *)
  if n =( 0 :: int) then None else
  (* | n -> *) Some (() , n)))"

  (* end *)

definition hex_bits_5_matches_prefix  :: " 'a Bitvector_class \<Rightarrow> string \<Rightarrow>('a*int)option "  where 
     " hex_bits_5_matches_prefix dict_Sail2_values_Bitvector_a s = (
  (case  maybe_int_of_prefix s of
    None => None
  | Some (n, len) =>
     if(( 0 :: int) \<le> n) \<and> (n <( 32 :: int)) then
       Some (((of_int_method   dict_Sail2_values_Bitvector_a)(( 5 :: int)) n, len))
     else
       None
  ))"


definition hex_bits_6_matches_prefix  :: " 'a Bitvector_class \<Rightarrow> string \<Rightarrow>('a*int)option "  where 
     " hex_bits_6_matches_prefix dict_Sail2_values_Bitvector_a s = (
  (case  maybe_int_of_prefix s of
    None => None
  | Some (n, len) =>
     if(( 0 :: int) \<le> n) \<and> (n <( 64 :: int)) then
       Some (((of_int_method   dict_Sail2_values_Bitvector_a)(( 6 :: int)) n, len))
     else
       None
  ))"


definition hex_bits_12_matches_prefix  :: " 'a Bitvector_class \<Rightarrow> string \<Rightarrow>('a*int)option "  where 
     " hex_bits_12_matches_prefix dict_Sail2_values_Bitvector_a s = (
  (case  maybe_int_of_prefix s of
    None => None
  | Some (n, len) =>
     if(( 0 :: int) \<le> n) \<and> (n <( 4096 :: int)) then
       Some (((of_int_method   dict_Sail2_values_Bitvector_a)(( 12 :: int)) n, len))
     else
       None
  ))"


definition hex_bits_13_matches_prefix  :: " 'a Bitvector_class \<Rightarrow> string \<Rightarrow>('a*int)option "  where 
     " hex_bits_13_matches_prefix dict_Sail2_values_Bitvector_a s = (
  (case  maybe_int_of_prefix s of
    None => None
  | Some (n, len) =>
     if(( 0 :: int) \<le> n) \<and> (n <( 8192 :: int)) then
       Some (((of_int_method   dict_Sail2_values_Bitvector_a)(( 13 :: int)) n, len))
     else
       None
  ))"


definition hex_bits_16_matches_prefix  :: " 'a Bitvector_class \<Rightarrow> string \<Rightarrow>('a*int)option "  where 
     " hex_bits_16_matches_prefix dict_Sail2_values_Bitvector_a s = (
  (case  maybe_int_of_prefix s of
    None => None
  | Some (n, len) =>
     if(( 0 :: int) \<le> n) \<and> (n <( 65536 :: int)) then
       Some (((of_int_method   dict_Sail2_values_Bitvector_a)(( 16 :: int)) n, len))
     else
       None
  ))"



definition hex_bits_20_matches_prefix  :: " 'a Bitvector_class \<Rightarrow> string \<Rightarrow>('a*int)option "  where 
     " hex_bits_20_matches_prefix dict_Sail2_values_Bitvector_a s = (
  (case  maybe_int_of_prefix s of
    None => None
  | Some (n, len) =>
     if(( 0 :: int) \<le> n) \<and> (n <( 1048576 :: int)) then
       Some (((of_int_method   dict_Sail2_values_Bitvector_a)(( 20 :: int)) n, len))
     else
       None
  ))"


definition hex_bits_21_matches_prefix  :: " 'a Bitvector_class \<Rightarrow> string \<Rightarrow>('a*int)option "  where 
     " hex_bits_21_matches_prefix dict_Sail2_values_Bitvector_a s = (
  (case  maybe_int_of_prefix s of
    None => None
  | Some (n, len) =>
     if(( 0 :: int) \<le> n) \<and> (n <( 2097152 :: int)) then
       Some (((of_int_method   dict_Sail2_values_Bitvector_a)(( 21 :: int)) n, len))
     else
       None
  ))"


definition hex_bits_32_matches_prefix  :: " 'a Bitvector_class \<Rightarrow> string \<Rightarrow>('a*int)option "  where 
     " hex_bits_32_matches_prefix dict_Sail2_values_Bitvector_a s = (
  (case  maybe_int_of_prefix s of
    None => None
  | Some (n, len) =>
     if(( 0 :: int) \<le> n) \<and> (n <( 4294967296 :: int)) then
       Some (((of_int_method   dict_Sail2_values_Bitvector_a)(( 2147483648 :: int)) n, len))
     else
       None
  ))"

end
