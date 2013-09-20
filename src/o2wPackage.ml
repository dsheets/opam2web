(***********************************************************************)
(*                                                                     *)
(*    Copyright 2012-2013 OCamlPro                                     *)
(*    Copyright 2012 INRIA                                             *)
(*                                                                     *)
(*  All rights reserved.  This file is distributed under the terms of  *)
(*  the GNU Public License version 3.0.                                *)
(*                                                                     *)
(*  OPAM is distributed in the hope that it will be useful,            *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of     *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the      *)
(*  GNU General Public License for more details.                       *)
(*                                                                     *)
(***********************************************************************)

open OpamTypes
open Cow.Html
open O2wTypes

(* Comparison function using string representation of an OpamPackage *)
let compare_alphanum  p1 p2 =
  String.compare (OpamPackage.to_string p1) (OpamPackage.to_string p2)

(* Comparison function using number of downloads for each package *)
let compare_popularity ?(reverse = false) pkg_stats p1 p2 =
  let pkg_count pkg =
    try OpamPackage.Name.Map.find (OpamPackage.name pkg) pkg_stats
    with Not_found -> Int64.zero in
  match pkg_count p1, pkg_count p2 with
  | c1, c2 when c1 <> c2 ->
    let c1, c2 = if reverse then c2, c1 else c1, c2 in
    Int64.compare c1 c2
  | _ -> compare_alphanum p1 p2

(* Comparison function using the last update time of packages *)
let compare_date ?(reverse = false) pkg_dates p1 p2 =
  let pkg_date pkg =
    try OpamPackage.Map.find pkg pkg_dates
    with Not_found -> 0. in
  match pkg_date p1, pkg_date p2 with
  | d1, d2 when d1 <> d2 ->
    let d1, d2 = if reverse then d2, d1 else d1, d2 in
    compare d1 d2
  | _ -> compare_alphanum p1 p2

let href ?href_prefix name version =
  let base = Printf.sprintf "pkg/%s/%s/"
      (OpamPackage.Name.to_string name) (OpamPackage.Version.to_string version) in
  match href_prefix with
  | None   -> base
  | Some p -> p ^ base

let are_preds_satisfied universe pkg =
  try
    let pkg_opam = OpamPackage.Map.find pkg universe.pkgs_opams in
    let tags = OpamFile.OPAM.tags pkg_opam in
    let rec is_satisfied = function
      | Tag t -> List.mem t tags
      | Repo r ->
        let (rn,_) = OpamPackage.Map.find pkg universe.pkg_idx in
        r = (OpamRepositoryName.to_string rn)
      | Not p -> not (is_satisfied p)
      | Depopt-> false
    in
    let rec aux = function
      | [] -> false
      | pred::rest ->
        if List.for_all is_satisfied pred then true else aux rest
    in
    if universe.preds = [] then true else aux universe.preds
  with Not_found -> false

(* Build a record representing information about a package *)
let get_info ~dates repo prefix pkg =
  let pkg_name = OpamPackage.Name.to_string (OpamPackage.name pkg) in
  let pkg_version = OpamPackage.Version.to_string (OpamPackage.version pkg) in
  let pkg_href = href (OpamPackage.name pkg) (OpamPackage.version pkg) in
  let descr = OpamFile.Descr.safe_read
    (OpamPath.Repository.descr repo prefix pkg) in
  let pkg_synopsis = OpamFile.Descr.synopsis descr in
  let pkg_descr_markdown = OpamFile.Descr.full descr in
  let short_descr, long_descr =
    match OpamMisc.cut_at pkg_descr_markdown '\n' with
    | None       -> pkg_descr_markdown, ""
    | Some (s,d) -> s, d in
  let pkg_descr =
    let to_html md = Cow.Markdown.to_html (Cow.Markdown_github.of_string md) in
    <:html<
      <h4>$str:short_descr$</h4>
      $to_html long_descr$
    >> in
  let pkg_url =
    let file = OpamPath.Repository.url repo prefix pkg in
    if OpamFilename.exists file then
      Some (OpamFile.URL.read file)
    else
      None in
  let pkg_title = Printf.sprintf "%s %s" pkg_name pkg_version in
  try
    let pkg_update =
      OpamPackage.Map.find pkg dates in
    Some {
      pkg_name;
      pkg_version;
      pkg_descr;
      pkg_synopsis;
      pkg_href;
      pkg_title;
      pkg_update;
      pkg_url;
    }
  with Not_found ->
    None

(* Returns a HTML description of the given package *)
let to_html ~href_prefix ~statistics universe pkg_info =
  let name = OpamPackage.Name.of_string pkg_info.pkg_name in
  let version = OpamPackage.Version.of_string pkg_info.pkg_version in
  let pkg = OpamPackage.create name version in
  let pkg_opam = OpamPackage.Map.find pkg universe.pkgs_opams in
  let version_links =
    let versions =
      try OpamPackage.Version.Set.elements
            (OpamPackage.Name.Map.find name universe.versions)
      with Not_found -> [version] in
    List.map
      (fun version ->
         let href = href ~href_prefix name version in
         let version = OpamPackage.Version.to_string version in
         if pkg_info.pkg_version = version then
           <:html<
             <li class="active">
               <a href="#">version $str: version$</a>
             </li>
           >>
         else
           <:html< <li><a href="$str: href$">$str: version$</a></li> >>)
      versions in
  let pkg_url = match pkg_info.pkg_url with
    | None          -> <:html< >>
    | Some url_file ->
      let kind = match OpamFile.URL.kind url_file with
        | Some k -> <:html< [$str: string_of_repository_kind k$] >>
        | None -> <:html< >> in
      let checksum = match OpamFile.URL.checksum url_file with
        | Some c -> <:html< <small>$str: c$</small> >>
        | None -> <:html< >> in
      let url = string_of_address (OpamFile.URL.url url_file) in
      <:html<
        <tr>
        <th>Source $kind$</th>
        <td>
          <a href="$str: url$" title="Download source">$str: url$</a><br />
          $checksum$
        </td>
        </tr>
      >> in
  let list name l : (string * Cow.Xml.t) option = match l with
    | []  -> None
    | [e] -> Some (name      , <:html<$str:e$>>)
    | l   -> Some (name ^ "s", <:html<$str:OpamMisc.pretty_list l$>>) in
  let pkg_author = list "Author" (OpamFile.OPAM.author pkg_opam) in
  let pkg_maintainer = list "Maintainer" (OpamFile.OPAM.maintainer pkg_opam) in
  let pkg_license = list "License" (OpamFile.OPAM.license pkg_opam) in
  let mk_url title url = <:html<
    <a href=$str: url$ title=$str:title$>$str: url$</a>
  >> in
  let more_info name =
    "More information about " ^ (OpamPackage.Name.to_string name) in
  let pkg_homepage = match OpamFile.OPAM.homepage pkg_opam with
    | [] -> <:html< >>
    | [e] -> <:html<
      <tr><th>Homepage</th><td>$mk_url (more_info name) e$</td></tr>
    >>
    | e::l -> let links = List.fold_left (fun p n ->
      <:html< $p$, $mk_url (more_info name) n$>>
    ) (mk_url (more_info name) e) l in
    <:html<
      <tr><th>Homepages</th><td>$links$</td></tr>
    >> in
  let pkg_tags = list "Tag" (OpamFile.OPAM.tags pkg_opam) in
  let pkg_update = O2wMisc.string_of_timestamp pkg_info.pkg_update in
  (* XXX: need to add hyperlink on package names *)
  let mk_formula name f = match f pkg_opam with
    | OpamFormula.Empty -> None
    | x                 -> Some (name, <:html<$str:OpamFormula.to_string x$>>) in
  let pkg_depends = mk_formula "Dependencies" OpamFile.OPAM.depends in
  let pkg_depopts = mk_formula "Optional dependencies" OpamFile.OPAM.depopts in
  let html_of_dependencies title dependencies =
    let deps = List.map (fun (pkg_name, constr_opt) ->
        let latest_version =
          try Some (OpamPackage.Name.Map.find pkg_name universe.max_versions)
          with Not_found -> None in
        let name = OpamPackage.Name.to_string pkg_name in
        let href = match latest_version with
          | None -> <:html< $str: name$ >>
          | Some v ->
            let href_str =href ~href_prefix pkg_name v in
            <:html< <a href="$str: href_str$">$str: name$</a> >>
        in
        let version = match constr_opt with
          | None -> ""
          | Some (r, v) ->
            Printf.sprintf "( %s %s )"
              (OpamFormula.string_of_relop r)
              (OpamPackage.Version.to_string v)
        in
        <:html<
          <tr>
            <td>
              $href$
              <small>$str: version$</small>
            </td>
          </tr>
        >>)
        dependencies
    in
    match deps with
    | [] -> []
    | _ -> <:html<
             <tr class="well">
             <th>$str: title$</th>
             </tr>
           >> :: deps
  in
  (* Keep only atomic formulas in dependency requirements
     TODO: handle any type of formula *)
  let depends_atoms = OpamFormula.atoms (OpamFile.OPAM.depends pkg_opam) in
  let dependencies = html_of_dependencies "Dependencies" depends_atoms in
  let depopts_atoms = OpamFormula.atoms (OpamFile.OPAM.depopts pkg_opam) in
  let depopts = html_of_dependencies "Optional" depopts_atoms in
  let requiredby =
    try OpamPackage.Name.Map.find (OpamPackage.name pkg) universe.reverse_deps
    with Not_found -> OpamPackage.Name.Set.empty in
  let requiredby_deps =
    List.map (fun name -> name, None) (OpamPackage.Name.Set.elements requiredby) in
  let requiredby_html =
    html_of_dependencies "Required by" requiredby_deps in
  let nodeps =
    <:html< <tr><td>No dependency</td></tr> >> in
  let pkg_stats = match statistics with
    | None -> <:html< >>
    | Some sset ->
      let s = sset.month_stats in
      let pkg_count =
        try OpamPackage.Map.find pkg s.pkg_stats
        with Not_found -> Int64.zero
      in
      let pkg_count_html = match pkg_count with
        | c when c = Int64.zero -> <:html< Not installed in the last month. >>
        | c when c = Int64.one ->
          <:html< Installed <strong>once</strong> in last month. >>
        | c ->
          <:html< Installed <strong>$str: Int64.to_string c$</strong> times in last month. >>
      in
      <:html<
        <tr>
          <th>Statistics</th>
          <td>
            $pkg_count_html$
          </td>
        </tr>
      >>
  in
  let mk_tr = function
    | None                   -> <:html<&>>
    | Some (title, contents) ->
      <:html<
            <tr>
              <th>$str: title$</th>
              <td>$contents$</td>
            </tr>
      >> in
  <:html<
    <h2>$str: pkg_info.pkg_name$</h2>

    <div class="row">
      <div class="span9">
        <div>
          <ul class="nav nav-pills">
            $list: version_links$
          </ul>
        </div>

        <table class="table">
          <tbody>
            $mk_tr pkg_author$
            $mk_tr pkg_license$
            $pkg_homepage$
            $mk_tr pkg_tags$
            $mk_tr pkg_maintainer$
            $mk_tr pkg_depends$
            $mk_tr pkg_depopts$
            <tr>
              <th>Last update</th>
              <td>
                $str: pkg_update$
              </td>
            </tr>
            $pkg_url$
            $pkg_stats$
          </tbody>
        </table>

        <div class="well">$pkg_info.pkg_descr$</div>

      </div>

      <div class="span3">
        <table class="table table-bordered">
          <tbody>
            $list: dependencies$
            $list: depopts$
            $list: requiredby_html$
            $match dependencies, depopts, requiredby_deps with
              | ([], [], []) -> nodeps
              | _            -> Cow.Html.nil$
          </tbody>
        </table>
      </div>
    </div>
  >>
