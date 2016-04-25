(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i camlp4deps: "tools/compat5b.cmo" i*)

(** Implementation of the TACTIC EXTEND macro. *)

open Q_util
open Argextend
open Compat

let dloc = <:expr< Loc.ghost >>

let plugin_name = <:expr< __coq_plugin_name >>

let rec make_patt = function
  | [] -> <:patt< [] >>
  | ExtNonTerminal (_, p) :: l ->
      <:patt< [ $lid:p$ :: $make_patt l$ ] >>
  | _::l -> make_patt l

let rec make_let raw e = function
  | [] -> <:expr< fun $lid:"ist"$ -> $e$ >>
  | ExtNonTerminal (g, p) :: l ->
      let t = type_of_user_symbol g in
      let loc = MLast.loc_of_expr e in
      let e = make_let raw e l in
      let v =
        if raw then <:expr< Genarg.out_gen $make_rawwit loc t$ $lid:p$ >>
               else <:expr< Tacinterp.Value.cast $make_topwit    loc t$ $lid:p$ >> in
      <:expr< let $lid:p$ = $v$ in $e$ >>
  | _::l -> make_let raw e l

let make_clause (pt,_,e) =
  (make_patt pt,
   vala None,
   make_let false e pt)

let make_fun_clauses loc s l =
  let map c = Compat.make_fun loc [make_clause c] in
  mlexpr_of_list map l

let get_argt e = <:expr< match $e$ with [ Genarg.ExtraArg tag -> tag | _ -> assert False ] >>

let rec mlexpr_of_symbol = function
| Ulist1 s -> <:expr< Extend.Ulist1 $mlexpr_of_symbol s$ >>
| Ulist1sep (s,sep) -> <:expr< Extend.Ulist1sep $mlexpr_of_symbol s$ $str:sep$ >>
| Ulist0 s -> <:expr< Extend.Ulist0 $mlexpr_of_symbol s$ >>
| Ulist0sep (s,sep) -> <:expr< Extend.Ulist0sep $mlexpr_of_symbol s$ $str:sep$ >>
| Uopt s -> <:expr< Extend.Uopt $mlexpr_of_symbol s$ >>
| Uentry e ->
  let arg = get_argt <:expr< $lid:"wit_"^e$ >> in
  <:expr< Extend.Uentry (Genarg.ArgT.Any $arg$) >>
| Uentryl (e, l) ->
  assert (e = "tactic");
  let arg = get_argt <:expr< Constrarg.wit_tactic >> in
  <:expr< Extend.Uentryl (Genarg.ArgT.Any $arg$) $mlexpr_of_int l$>>

let make_prod_item = function
  | ExtTerminal s -> <:expr< Tacentries.TacTerm $str:s$ >>
  | ExtNonTerminal (g, id) ->
    <:expr< Tacentries.TacNonTerm $default_loc$ $mlexpr_of_symbol g$ $mlexpr_of_ident id$ >>

let mlexpr_of_clause cl =
  mlexpr_of_list (fun (a,_,_) -> mlexpr_of_list make_prod_item a) cl

(** Special treatment of constr entries *)
let is_constr_gram = function
| ExtTerminal _ -> false
| ExtNonTerminal (Uentry "constr", _) -> true
| _ -> false

let make_var = function
  | ExtNonTerminal (_, p) -> Some p
  | _ -> assert false

let declare_tactic loc s c cl = match cl with
| [(ExtTerminal name) :: rem, _, tac] when List.for_all is_constr_gram rem ->
  (** The extension is only made of a name followed by constr entries: we do not
      add any grammar nor printing rule and add it as a true Ltac definition. *)
  let patt = make_patt rem in
  let vars = List.map make_var rem in
  let vars = mlexpr_of_list (mlexpr_of_option mlexpr_of_ident) vars in
  let entry = mlexpr_of_string s in
  let se = <:expr< { Tacexpr.mltac_tactic = $entry$; Tacexpr.mltac_plugin = $plugin_name$ } >> in
  let ml = <:expr< { Tacexpr.mltac_name = $se$; Tacexpr.mltac_index = 0 } >> in
  let name = mlexpr_of_string name in
  let tac = match rem with
  | [] ->
    (** Special handling of tactics without arguments: such tactics do not do
        a Proofview.Goal.nf_enter to compute their arguments. It matters for some
        whole-prof tactics like [shelve_unifiable]. *)
      <:expr< fun _ $lid:"ist"$ -> $tac$ >>
  | _ ->
      let f = Compat.make_fun loc [patt, vala None, <:expr< fun $lid:"ist"$ -> $tac$ >>] in
      <:expr< Tacinterp.lift_constr_tac_to_ml_tac $vars$ $f$ >>
  in
  (** Arguments are not passed directly to the ML tactic in the TacML node,
      the ML tactic retrieves its arguments in the [ist] environment instead.
      This is the rôle of the [lift_constr_tac_to_ml_tac] function. *)
  let body = <:expr< Tacexpr.TacFun ($vars$, Tacexpr.TacML ($dloc$, $ml$, [])) >> in
  let name = <:expr< Names.Id.of_string $name$ >> in
  declare_str_items loc
    [ <:str_item< do {
      let obj () = Tacenv.register_ltac True False $name$ $body$ in
      try do {
        Tacenv.register_ml_tactic $se$ [|$tac$|];
        Mltop.declare_cache_obj obj $plugin_name$; }
      with [ e when Errors.noncritical e ->
        Pp.msg_warning
          (Pp.app
            (Pp.str ("Exception in tactic extend " ^ $entry$ ^": "))
            (Errors.print e)) ]; } >>
    ]
| _ ->
  (** Otherwise we add parsing and printing rules to generate a call to a
      TacML tactic. *)
  let entry = mlexpr_of_string s in
  let se = <:expr< { Tacexpr.mltac_tactic = $entry$; Tacexpr.mltac_plugin = $plugin_name$ } >> in
  let gl = mlexpr_of_clause cl in
  let obj = <:expr< fun () -> Tacentries.add_ml_tactic_notation $se$ $gl$ >> in
  declare_str_items loc
    [ <:str_item< do {
      try do {
        Tacenv.register_ml_tactic $se$ (Array.of_list $make_fun_clauses loc s cl$);
        Mltop.declare_cache_obj $obj$ $plugin_name$; }
      with [ e when Errors.noncritical e ->
        Pp.msg_warning
          (Pp.app
            (Pp.str ("Exception in tactic extend " ^ $entry$ ^": "))
            (Errors.print e)) ]; } >>
    ]

open Pcaml
open PcamlSig (* necessary for camlp4 *)

EXTEND
  GLOBAL: str_item;
  str_item:
    [ [ "TACTIC"; "EXTEND"; s = tac_name;
        c = OPT [ "CLASSIFIED"; "BY"; c = LIDENT -> <:expr< $lid:c$ >> ];
        OPT "|"; l = LIST1 tacrule SEP "|";
        "END" ->
         declare_tactic loc s c l ] ]
  ;
  tacrule:
    [ [ "["; l = LIST1 tacargs; "]";
        c = OPT [ "=>"; "["; c = Pcaml.expr; "]" -> c ];
        "->"; "["; e = Pcaml.expr; "]" ->
	(match l with
	  | ExtNonTerminal _ :: _ ->
	    (* En attendant la syntaxe de tacticielles *)
	    failwith "Tactic syntax must start with an identifier"
	  | _ -> (l,c,e))
    ] ]
  ;
  tacargs:
    [ [ e = LIDENT; "("; s = LIDENT; ")" ->
        let e = parse_user_entry e "" in
        ExtNonTerminal (e, s)
      | e = LIDENT; "("; s = LIDENT; ","; sep = STRING; ")" ->
        let e = parse_user_entry e sep in
        ExtNonTerminal (e, s)
      | s = STRING ->
	let () = if s = "" then failwith "Empty terminal." in
        ExtTerminal s
    ] ]
  ;
  tac_name:
    [ [ s = LIDENT -> s
      | s = UIDENT -> s
    ] ]
  ;
  END
