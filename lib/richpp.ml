(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2015     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Util
open Xml_datatype

type 'annotation located = {
  annotation : 'annotation;
  startpos   : int;
  endpos     : int
}

type 'a stack =
| Leaf
| Node of string * (string, 'a located) gxml list * int * 'a stack

type 'a context = {
  mutable stack : 'a stack;
  (** Pending opened nodes *)
  mutable offset : int;
  (** Quantity of characters printed so far *)
  mutable annotations : 'a option Int.Map.t;
  (** Map associating annotations to indexes *)
  mutable index : int;
  (** Current index of annotations *)
}

(** We use Format to introduce tags inside the pretty-printed document.
    Each inserted tag is a fresh index that we keep in sync with the contents
    of annotations.

    We build an XML tree on the fly, by plugging ourselves in Format tag
    marking functions. As those functions are called when actually writing to
    the device, the resulting tree is correct.
*)
let rich_pp annotate ppcmds =

  let context = {
    stack = Leaf;
    offset = 0;
    annotations = Int.Map.empty;
    index = (-1);
  } in

  let pp_tag obj =
    let index = context.index + 1 in
    let () = context.index <- index in
    let obj = annotate obj in
    let () = context.annotations <- Int.Map.add index obj context.annotations in
    string_of_int index
  in

  let pp_buffer = Buffer.create 13 in

  let push_pcdata () =
    (** Push the optional PCData on the above node *)
    let len = Buffer.length pp_buffer in
    if len = 0 then ()
    else match context.stack with
    | Leaf -> assert false
    | Node (node, child, pos, ctx) ->
      let data = Buffer.contents pp_buffer in
      let () = Buffer.clear pp_buffer in
      let () = context.stack <- Node (node, PCData data :: child, pos, ctx) in
      context.offset <- context.offset + len
  in

  let open_xml_tag tag =
    let () = push_pcdata () in
    context.stack <- Node (tag, [], context.offset, context.stack)
  in

  let close_xml_tag tag =
    let () = push_pcdata () in
    match context.stack with
    | Leaf -> assert false
    | Node (node, child, pos, ctx) ->
      let () = assert (String.equal tag node) in
      let annotation =
        try Int.Map.find (int_of_string node) context.annotations
        with _ -> None
      in
      let child = List.rev child in
      let xml = match annotation with
      | None -> child (** Ignore the node *)
      | Some annotation ->
        let annotation = {
          annotation = annotation;
          startpos = pos;
          endpos = context.offset;
        } in
        [Element (node, annotation, child)]
      in
      match ctx with
      | Leaf ->
        (** Final node: we keep the result in a dummy context *)
        context.stack <- Node ("", List.rev xml, 0, Leaf)
      | Node (node, child, pos, ctx) ->
        context.stack <- Node (node, List.rev_append xml child, pos, ctx)
  in

  let open Format in

  let ft = formatter_of_buffer pp_buffer in

  let tag_functions = {
    mark_open_tag = (fun tag -> let () = open_xml_tag tag in "");
    mark_close_tag = (fun tag -> let () = close_xml_tag tag in "");
    print_open_tag = ignore;
    print_close_tag = ignore;
  } in

  pp_set_formatter_tag_functions ft tag_functions;
  pp_set_mark_tags ft true;

  (** The whole output must be a valid document. To that
      end, we nest the document inside <pp> tags. *)
  pp_open_tag ft "pp";
  Pp.(pp_with ~pp_tag ft ppcmds);
  pp_close_tag ft ();

  (** Get the resulting XML tree. *)
  let () = pp_print_flush ft () in
  let () = assert (Buffer.length pp_buffer = 0) in
  match context.stack with
  | Node ("", [xml], 0, Leaf) -> xml
  | _ -> assert false


let annotations_positions xml =
  let rec node accu = function
    | Element (_, { annotation = annotation; startpos; endpos }, cs) ->
      children ((annotation, (startpos, endpos)) :: accu) cs
    | _ ->
      accu
  and children accu cs =
    List.fold_left node accu cs
  in
  node [] xml

let xml_of_rich_pp tag_of_annotation attributes_of_annotation xml =
  let rec node = function
    | Element (index, { annotation; startpos; endpos }, cs) ->
      let attributes =
        [ "startpos", string_of_int startpos;
          "endpos", string_of_int endpos
        ]
        @ (attributes_of_annotation annotation)
      in
      let tag = tag_of_annotation annotation in
      Element (tag, attributes, List.map node cs)
    | PCData s ->
      PCData s
  in
  node xml


