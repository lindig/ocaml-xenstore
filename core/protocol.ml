(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Pervasives
open Sexplib
open Sexplib.Std

(* One of the records below contains a Buffer.t *)
module Buffer = struct
  include Buffer
  type _t = string with sexp
  let t_of_sexp s =
    let _t = _t_of_sexp s in
    let b = Buffer.create (String.length _t) in
    Buffer.add_string b _t;
    b
  let sexp_of_t t =
    let _t = Buffer.contents t in
    sexp_of__t _t
end

(* The IntroduceDomain message includes a Nativeint.t *)
module Nativeint = struct
  include Nativeint

  type _t = string with sexp
  let t_of_sexp s =
    let _t = _t_of_sexp s in
    Nativeint.of_string _t
  let sexp_of_t t =
    let _t = Nativeint.to_string t in
    sexp_of__t _t
end

let ( |> ) f g = g f
let ( ++ ) f g x = f (g x)

type ('a, 'b) result = [
| `Ok of 'a
| `Error of 'b
] with sexp

module Op = struct
  type t =
    | Debug | Directory | Read | Getperms
    | Watch | Unwatch | Transaction_start
    | Transaction_end | Introduce | Release
    | Getdomainpath | Write | Mkdir | Rm
    | Setperms | Watchevent | Error | Isintroduced
    | Resume | Set_target
  | Restrict
  with sexp

(* The index of the value in the array is the integer representation used
   by the wire protocol. Every element of t exists exactly once in the array. *)
let on_the_wire =
  [| Debug; Directory; Read; Getperms;
     Watch; Unwatch; Transaction_start;
     Transaction_end; Introduce; Release;
     Getdomainpath; Write; Mkdir; Rm;
     Setperms; Watchevent; Error; Isintroduced;
     Resume; Set_target;
   Restrict
  |]

let of_int32 i =
  let i = Int32.to_int i in
  if i >= 0 && i < Array.length on_the_wire
  then `Ok (on_the_wire.(i))
  else `Error (Printf.sprintf "Unknown xenstore operation id: %d. Possible new protocol version? Or malfunctioning peer?" i)

let to_int32 x =
  match snd (Array.fold_left
    (fun (idx, result) v -> if x = v then (idx + 1, Some idx) else (idx + 1, result))
    (0, None) on_the_wire) with
    | None -> assert false (* impossible since on_the_wire contains each element *)
    | Some i -> Int32.of_int i

let all = Array.to_list on_the_wire
end

let rec split_string ?limit:(limit=(-1)) c s =
  let i = try String.index s c with Not_found -> -1 in
  let nlimit = if limit = -1 || limit = 0 then limit else limit - 1 in
  if i = -1 || nlimit = 0 then
    [ s ]
  else
    let a = String.sub s 0 i
    and b = String.sub s (i + 1) (String.length s - i - 1) in
    a :: (split_string ~limit: nlimit c b)

module ACL = struct
  type perm =
    | NONE
    | READ
    | WRITE
    | RDWR
  with sexp

  let char_of_perm = function
    | READ -> 'r'
    | WRITE -> 'w'
    | RDWR -> 'b'
    | NONE -> 'n'

  let perm_of_char = function
    | 'r' -> Some READ
    | 'w' -> Some WRITE
    | 'b' -> Some RDWR
    | 'n' -> Some NONE
    | _ -> None

  type domid = int with sexp

  type t = {
    owner: domid;             (** domain which "owns", has full access *)
    other: perm;              (** default permissions for all others... *)
    acl: (domid * perm) list; (** ... unless overridden in the ACL *)
  } with sexp

  let marshal perms =
    let string_of_perm (id, perm) = Printf.sprintf "%c%u" (char_of_perm perm) id in
    String.concat "\000" (List.map string_of_perm ((perms.owner,perms.other) :: perms.acl))

  let unmarshal s =
      (* A perm is stored as '<c>domid' *)
    let perm_of_char_exn x = match (perm_of_char x) with Some y -> y | None -> raise Not_found in
    try
      let perm_of_string s =
        if String.length s < 2
        then invalid_arg (Printf.sprintf "Permission string too short: '%s'" s);
        int_of_string (String.sub s 1 (String.length s - 1)), perm_of_char_exn s.[0] in
      let l = List.map perm_of_string (split_string '\000' s) in
      match l with
        | (owner, other) :: l -> Some { owner = owner; other = other; acl = l }
        | [] -> Some { owner = 0; other = NONE; acl = [] }
      with e ->
      None
end

type t = {
  tid: int32;
  rid: int32;
  ty: Op.t;
  len: int;
  data: Buffer.t;
} with sexp

cstruct header {
  uint32_t ty;
  uint32_t rid;
  uint32_t tid;
  uint32_t len
} as little_endian

let marshal pkt =
  let header = Cstruct.create sizeof_header in
  let len = Int32.of_int (Buffer.length pkt.data) in
  let ty = Op.to_int32 pkt.ty in
  set_header_ty header ty;
  set_header_rid header pkt.rid;
  set_header_tid header pkt.tid;
  set_header_len header len;
  Cstruct.to_string header ^ (Buffer.contents pkt.data)

let get_tid pkt = pkt.tid
let get_ty pkt = pkt.ty

let get_data pkt =
  if pkt.len > 0 && Buffer.nth pkt.data (pkt.len - 1) = '\000' then
    Buffer.sub pkt.data 0 (pkt.len - 1)
  else
    Buffer.contents pkt.data
let get_data_raw pkt = Buffer.contents pkt.data

let get_rid pkt = pkt.rid

module Parser = struct
  (** Incrementally parse packets *)

  let header_size = 16

  let xenstore_payload_max = 4096 (* xen/include/public/io/xs_wire.h *)

  type packet = t with sexp

  type state =
    | Done of (packet, string) result
    | Continue of int
  with sexp

  type t =
    | ReadingHeader of int * string
    | ReadingBody of packet
    | Finished of (packet, string) result
  with sexp

  let create () = ReadingHeader (0, String.make header_size '\000')

  let state = function
    | ReadingHeader(got_already, _) -> Continue (header_size - got_already)
    | ReadingBody pkt -> Continue (pkt.len - (Buffer.length pkt.data))
    | Finished r -> Done r

  let parse_header str =
    let header = Cstruct.create sizeof_header in
    Cstruct.blit_from_string str 0 header 0 sizeof_header;
    let ty = get_header_ty header in
    let rid = get_header_rid header in
    let tid = get_header_tid header in
    let len = get_header_len header in

    let len = Int32.to_int len in
    (* A packet which is bigger than xenstore_payload_max is illegal.
       This will leave the guest connection is a bad state and will
       be hard to recover from without restarting the connection
       (ie rebooting the guest) *)
    let len = max 0 (min xenstore_payload_max len) in

    begin match Op.of_int32 ty with
    | `Ok ty ->
      let t = {
        tid = tid;
        rid = rid;
        ty = ty;
        len = len;
        data = Buffer.create len;
        } in
      if len = 0
      then Finished (`Ok t)
      else ReadingBody t
    | `Error x -> Finished (`Error x)
    end

  let input state bytes =
    match state with
      | ReadingHeader(got_already, str) ->
  String.blit bytes 0 str got_already (String.length bytes);
  let got_already = got_already + (String.length bytes) in
  if got_already < header_size
  then ReadingHeader(got_already, str)
  else parse_header str
      | ReadingBody x ->
  Buffer.add_string x.data bytes;
  let needed = x.len - (Buffer.length x.data) in
  if needed > 0
  then ReadingBody x
  else Finished (`Ok x)
      | Finished f -> Finished f
end

(* Should we switch to an explicit stream abstraction here? *)
module type IO = sig
  type 'a t
  val return: 'a -> 'a t
  val ( >>= ): 'a t -> ('a -> 'b t) -> 'b t

  type channel
  val read: channel -> string -> int -> int -> int t
  val write: channel -> string -> int -> int -> unit t
end

module PacketStream = functor(IO: IO) -> struct
  let ( >>= ) = IO.( >>= )
  let return = IO.return

  type stream = {
    channel: IO.channel;
    mutable incoming_pkt: Parser.t; (* incrementally parses the next packet *)
  }

  let make t = {
    channel = t;
    incoming_pkt = Parser.create ();
  }

  (* [recv client] returns a single Packet, or fails *)
  let rec recv t =
    let open Parser in match Parser.state t.incoming_pkt with
    | Done (`Ok pkt) ->
      t.incoming_pkt <- create ();
      return (`Ok pkt)
    | Done (`Error x) -> return (`Error x)
    | Continue x ->
      let buf = String.make x '\000' in
      IO.read t.channel buf 0 x
      >>= function
      | 0 -> return (`Error "The xenstore connection has closed")
      | n ->
        let fragment = String.sub buf 0 n in
	    t.incoming_pkt <- input t.incoming_pkt fragment;
	    recv t

  (* [send client pkt] sends [pkt] and returns (), or fails *)
  let send t request =
    let req = marshal request in
	IO.write t.channel req 0 (String.length req)
end

module Token = struct
  type t = string with sexp

  (** [to_user_string x] returns the user-supplied part of the watch token *)
  let to_user_string x = Scanf.sscanf x "%d:%s" (fun _ x -> x)

  let to_debug_string x = x

  let unmarshal x = x
  let marshal x = x
end

let data_concat ls = (String.concat "\000" ls) ^ "\000"

let create tid rid ty data =
  let len = String.length data in
  let b = Buffer.create len in
  Buffer.add_string b data;
  {
    tid = tid;
    rid = rid;
    ty = ty;
    len = len;
    data = b;
  }

let set_data pkt (data: string) =
  let len = String.length data in
  let b = Buffer.create len in
  Buffer.add_string b data;
  { pkt with len = len; data = b }


module Path = struct
  module Element = struct
    type t = string with sexp

    let char_is_valid c =
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c = '_' || c = '-' || c = '@'

    exception Invalid_char of char

    let assert_valid x =
      for i = 0 to String.length x - 1 do
        if not(char_is_valid x.[i])
        then raise (Invalid_char x.[i])
      done

    let of_string x = assert_valid x; x
    let to_string x = x

  end

  type t = Element.t list with sexp

  let empty = []

  exception Invalid_path of string * string

  let of_string path =
    if path = ""
    then raise (Invalid_path (path, "paths may not be empty"));
    if String.length path > 1024
    then raise (Invalid_path (path, "paths may not be larger than 1024 bytes"));
    let absolute, fragments = match split_string '/' path with
    | "" :: "" :: [] -> true, []
    | "" :: path -> true, path (* preceeding '/' *)
    | path -> false, path in
    List.map (fun fragment ->
      try Element.of_string fragment
      with Element.Invalid_char c -> raise (Invalid_path(path, Printf.sprintf "valid paths contain only ([a-z]|[A-Z]|[0-9]|-|_|@])+ but this contained '%c'" c))
    ) fragments

  let to_list t = t

  let to_string_list t = t

  let of_string_list xs = List.map Element.of_string xs

  let to_string t = String.concat "/" (List.map Element.to_string t)

  let dirname = function
  | [] -> []
  | x -> List.(rev (tl (rev x)))

  let basename x = List.(hd (rev x))

  let walk f path initial = List.fold_left (fun x y -> f y x) initial path

  let fold f path initial =
    let rec loop acc prefix = function
    | [] -> acc
    | x :: xs ->
      let prefix = prefix @ [x] in
      loop (f prefix acc) prefix xs in
    loop initial [] path

  let iter f path = fold (fun prefix () -> f prefix) path ()

  let common_prefix (p1: t) (p2: t) =
    let rec compare l1 l2 = match l1, l2 with
    | h1 :: tl1, h2 :: tl2 ->
      if h1 = h2 then h1 :: (compare tl1 tl2) else []
    | _, [] | [], _ ->
      (* if l1 or l2 is empty, we found the equal part already *)
      [] in
    compare p1 p2

  (* OLD:
  let get_hierarchy path = [] :: (List.rev (fold (fun path acc -> path :: acc) path []))
  get_hierarchy [1;2;3] == [ []; [1]; [1;2]; [1;2;3] ]
  *)
end

module Name = struct
  type predefined =
  | IntroduceDomain
  | ReleaseDomain
  with sexp

  type t =
  | Predefined of predefined
  | Absolute of Path.t
  | Relative of Path.t
  with sexp

  let of_string = function
  | "@introduceDomain" -> Predefined IntroduceDomain
  | "@releaseDomain" -> Predefined ReleaseDomain
  | path when path <> "" && path.[0] = '/' -> Absolute (Path.of_string path)
  | path -> Relative (Path.of_string path)

  let to_string = function
  | Predefined IntroduceDomain -> "@introduceDomain"
  | Predefined ReleaseDomain -> "@releaseDomain"
  | Absolute path -> "/" ^ (Path.to_string path)
  | Relative path ->        Path.to_string path

  let is_relative = function
  | Relative _ -> true
  | _ -> false

  let resolve t relative_to = match t, relative_to with
  | Relative path, Absolute dir -> Absolute (dir @ path)
  | t, _ -> t

  let relative t base = match t, base with
  | Absolute t, Absolute base ->
    (* If [base] is a prefix of [t], strip it off *)
    let rec f x y = match x, y with
    | x :: xs, y :: ys when x = y -> f xs ys
    | [], y -> Relative y
    | _, _ -> Absolute t in
    f base t
  | _, _ -> t

  let to_path x = match x with
  | Predefined _ -> raise (Path.Invalid_path(to_string x, "not a valid path"))
  | Absolute p -> p
  | Relative p -> p
end

module Response = struct

  type payload =
  | Read of string
  | Directory of string list
  | Getperms of ACL.t
  | Getdomainpath of string
  | Transaction_start of int32
  | Write
  | Mkdir
  | Rm
  | Setperms
  | Watch
  | Unwatch
  | Transaction_end
  | Debug of string list
  | Introduce
  | Resume
  | Release
  | Set_target
  | Restrict
  | Isintroduced of bool
  | Error of string
  | Watchevent of string * string
  with sexp

  let ty_of_payload = function
    | Read _ -> Op.Read
    | Directory _ -> Op.Directory
    | Getperms perms -> Op.Getperms
    | Getdomainpath _ -> Op.Getdomainpath
    | Transaction_start _ -> Op.Transaction_start
    | Debug _ -> Op.Debug
    | Isintroduced _ -> Op.Isintroduced
    | Watchevent (_, _) -> Op.Watchevent
    | Error _ -> Op.Error
    | Write -> Op.Write
    | Mkdir -> Op.Mkdir
    | Rm -> Op.Rm
    | Setperms -> Op.Setperms
    | Watch -> Op.Watch
    | Unwatch -> Op.Unwatch
    | Transaction_end -> Op.Transaction_end
    | Introduce -> Op.Introduce
    | Resume -> Op.Resume
    | Release -> Op.Release
    | Set_target -> Op.Set_target
    | Restrict -> Op.Restrict

  let ok = "OK\000"

  let data_of_payload = function
    | Read x                   -> x
    | Directory ls             -> if ls = [] then "" else data_concat ls
    | Getperms perms           -> data_concat [ ACL.marshal perms ]
    | Getdomainpath x          -> data_concat [ x ]
    | Transaction_start tid    -> data_concat [ Int32.to_string tid ]
    | Debug items              -> data_concat items
    | Isintroduced b           -> data_concat [ if b then "T" else "F" ]
    | Watchevent (path, token) -> data_concat [ path; token ]
    | Error x                  -> data_concat [ x ]
    | _                        -> ok

  let marshal x tid rid =
    create tid rid (ty_of_payload x) (data_of_payload x)
end

module Request = struct

	type path_op =
	| Read
	| Directory
	| Getperms
	| Write of string
	| Mkdir
	| Rm
	| Setperms of ACL.t
        with sexp

	type payload =
	| PathOp of string * path_op
	| Getdomainpath of int
	| Transaction_start
	| Watch of string * string
	| Unwatch of string * string
	| Transaction_end of bool
	| Debug of string list
	| Introduce of int * Nativeint.t * int
	| Resume of int
	| Release of int
	| Set_target of int * int
	| Restrict of int
	| Isintroduced of int
	| Error of string
	| Watchevent of string
        with sexp

	open Printf
	exception Parse_failure

	let strings data = split_string '\000' data

	(* String must be NUL-terminated *)
	let one_string data =
		let args = split_string ~limit:2 '\000' data in
		match args with
		| x :: [] ->
			raise Parse_failure
		| x :: "" :: [] -> x
		| _       ->
			raise Parse_failure

	let two_strings data =
		let args = split_string ~limit:2 '\000' data in
		match args with
		| a :: b :: [] -> a, b
		| a :: []      ->
			raise Parse_failure
		| _            ->
			raise Parse_failure

	let acl x = match ACL.unmarshal x with
		| Some x -> x
		| None ->
			raise Parse_failure

	let domid s =
		let v = ref 0 in
		let is_digit c = c >= '0' && c <= '9' in
		let len = String.length s in
		let i = ref 0 in
		while !i < len && not (is_digit s.[!i]) do incr i done;
		while !i < len && is_digit s.[!i]
		do
			let x = (Char.code s.[!i]) - (Char.code '0') in
			v := !v * 10 + x;
			incr i
		done;
		!v

	let bool = function
		| "F" -> false
		| "T" -> true
		| data ->
			raise Parse_failure

	let parse_exn request =
		let data = get_data_raw request in
		match get_ty request with
		| Op.Read -> PathOp (data |> one_string, Read)
		| Op.Directory -> PathOp (data |> one_string, Directory)
		| Op.Getperms -> PathOp (data |> one_string, Getperms)
		| Op.Getdomainpath -> Getdomainpath (data |> one_string |> domid)
		| Op.Transaction_start -> Transaction_start
		| Op.Write ->
			let path, value = two_strings data in
			PathOp (path, Write value)
		| Op.Mkdir -> PathOp (data |> one_string, Mkdir)
		| Op.Rm -> PathOp (data |> one_string, Rm)
		| Op.Setperms ->
			let path, perms = two_strings data in
			(* strip everything from the last NUL onwards *)
			let perms = String.sub perms 0 (String.rindex perms '\000') in
			let perms = acl perms in
			PathOp(path, Setperms perms)
		| Op.Watch ->
			let path, token = two_strings data in
			(* strip everything from the last NUL onwards *)
			let token = String.sub token 0 (String.rindex token '\000') in
			Watch(path, token)
		| Op.Unwatch ->
			let path, token = two_strings data in
			Unwatch(path, token)
		| Op.Transaction_end -> Transaction_end(data |> one_string |> bool)
		| Op.Debug -> Debug (strings data)
		| Op.Introduce ->
			begin match strings data with
			| d :: mfn :: port :: _ ->
				let d = domid d in
				let mfn = Nativeint.of_string mfn in
				let port = int_of_string port in
				Introduce (d, mfn, port)
			| _ ->
				raise Parse_failure
			end
		| Op.Resume -> Resume (data |> one_string |> domid)
		| Op.Release -> Release (data |> one_string |> domid)
		| Op.Set_target ->
			let mine, yours = two_strings data in
			let mine = domid mine and yours = domid yours in
			Set_target(mine, yours)
		| Op.Restrict -> Restrict (data |> one_string |> domid)
		| Op.Isintroduced -> Isintroduced (data |> one_string |> domid)
		| Op.Error -> Error(data |> one_string)
		| Op.Watchevent -> Watchevent(data |> one_string)

	let parse request =
		try
			Some (parse_exn request)
		with _ -> None

        let ty_of_payload = function
		| PathOp(_, Directory) -> Op.Directory
		| PathOp(_, Read) -> Op.Read
		| PathOp(_, Getperms) -> Op.Getperms
		| Debug _ -> Op.Debug
		| Watch (_, _) -> Op.Watch
		| Unwatch (_, _) -> Op.Unwatch
		| Transaction_start -> Op.Transaction_start
		| Transaction_end _ -> Op.Transaction_end
		| Introduce(_, _, _) -> Op.Introduce
		| Release _ -> Op.Release
		| Resume _ -> Op.Resume
		| Getdomainpath _ -> Op.Getdomainpath
		| PathOp(_, Write _) -> Op.Write
		| PathOp(_, Mkdir) -> Op.Mkdir
		| PathOp(_, Rm) -> Op.Rm
		| PathOp(_, Setperms _) -> Op.Setperms
		| Set_target (_, _) -> Op.Set_target
		| Restrict _ -> Op.Restrict
		| Isintroduced _ -> Op.Isintroduced
                | Watchevent _ -> Op.Watchevent
                | Error _ -> Op.Error

	let transactional_of_payload = function
		| PathOp(_, _)
		| Transaction_end _ -> true
		| _ -> false

	let data_of_payload = function
		| PathOp(path, Write value) ->
			path ^ "\000" ^ value (* no NULL at the end *)
		| PathOp(path, Setperms perms) ->
			data_concat [ path; ACL.marshal perms ]
		| PathOp(path, _) -> data_concat [ path ]
		| Debug commands -> data_concat commands
		| Watch (path, token)
		| Unwatch (path, token) -> data_concat [ path; token ]
		| Transaction_start -> data_concat []
		| Transaction_end commit -> data_concat [ if commit then "T" else "F" ]
		| Introduce(domid, mfn, port) ->
			data_concat [
				Printf.sprintf "%u" domid;
				Printf.sprintf "%nu" mfn;
				string_of_int port;
			]
		| Release domid
		| Resume domid
		| Getdomainpath domid
		| Restrict domid
		| Isintroduced domid ->
			data_concat [ Printf.sprintf "%u" domid; ]
		| Set_target (mine, yours) ->
			data_concat [ Printf.sprintf "%u" mine; Printf.sprintf "%u" yours; ]
                | Watchevent _
                | Error _ ->
                        (* It's illegal to create a request with a Watchevent or an Error.
                           A well-behaved client (like ours) will never do this, so this code
                           is never reached. *)
                        failwith "it's illegal to create a request with a Watchevent or an Error"

	let marshal x tid rid =
		create
			(if transactional_of_payload x then tid else 0l)
			rid
			(ty_of_payload x)
			(data_of_payload x)
end

module Unmarshal = struct
  let some x = Some x
  let int_of_string_opt x = try Some(int_of_string x) with _ -> None
  let int32_of_string_opt x = try Some(Int32.of_string x) with _ -> None
  let unit_of_string_opt x = if x = "" then Some () else None
  let ok x = if x = "OK" then Some () else None

  let string = some ++ get_data
  let list = some ++ split_string '\000' ++ get_data
  let acl = ACL.unmarshal ++ get_data
  let int = int_of_string_opt ++ get_data
  let int32 = int32_of_string_opt ++ get_data
  let unit = unit_of_string_opt ++ get_data
  let ok = ok ++ get_data
end

exception Enoent of string
exception Eagain
exception Invalid
exception Error of string

let response hint sent received f = match get_ty sent, get_ty received with
  | _, Op.Error ->
    begin match get_data received with
      | "ENOENT" -> raise (Enoent hint)
      | "EAGAIN" -> raise Eagain
      | "EINVAL" -> raise Invalid
      | s -> raise (Error s)
    end
  | x, y when x = y ->
    begin match f received with
      | None -> raise (Error (Printf.sprintf "failed to parse response (hint:%s) (payload:%s)" hint (get_data received)))
      | Some z -> z
    end
  | x, y ->
    raise (Error (Printf.sprintf "unexpected packet: expected %s; got %s"
      (Sexp.to_string_hum (Op.sexp_of_t x)) (Sexp.to_string_hum (Op.sexp_of_t y))))
