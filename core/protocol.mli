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

(** XenStore protocol. *)

type t with sexp
(** A valid packet. *)

type ('a, 'b) result = [
| `Ok of 'a
| `Error of 'b
]

module Op : sig
  type t =
    | Debug
    | Directory
    | Read
    | Getperms
    | Watch
    | Unwatch
    | Transaction_start
    | Transaction_end
    | Introduce
    | Release
    | Getdomainpath
    | Write
    | Mkdir
    | Rm
    | Setperms
    | Watchevent
    | Error
    | Isintroduced
    | Resume
    | Set_target
    | Restrict
  with sexp
  (** The type of xenstore operation. *)

  val all: t list
  (** All known operations *)

  val of_int32: int32 -> (t, string) result
  (** Map an int32 onto a [t]. If no mapping exists then the best we can do
      is log the result string and close the connection. *)

  val to_int32: t -> int32
end

module ACL : sig

  type perm =
    | NONE
    | READ
    | WRITE
    | RDWR
  with sexp

  val char_of_perm: perm -> char
  val perm_of_char: char -> perm option

  type domid = int with sexp

  type t = {
    owner: domid;             (** domain which "owns", has full access *)
    other: perm;              (** default permissions for all others... *)
    acl: (domid * perm) list; (** ... unless overridden in the ACL *)
  } with sexp

  val unmarshal: string -> t option
  val marshal: t -> string
end
(** Access control lists. *)

module Parser : sig

  type state =
    | Done of (t, string) result (** finished, either with a packet or an error *)
    | Continue of int            (** we still need 'n' bytes *)
  with sexp

  type t with sexp
  (** The internal state of the parser. *)

  val create: unit -> t
  (** Create a parser set to the initial state. *)

  val state: t -> state
  (** Query the state of the parser. *)

  val input: t -> string -> t
  (** Input some bytes into the parser. Must be no more than needed
      (see Need_more_data above). *)
end
(** Incrementally parse packets. *)

module type IO = sig
  type 'a t
  val return: 'a -> 'a t
  val ( >>= ): 'a t -> ('a -> 'b t) -> 'b t

  type channel
  val read: channel -> string -> int -> int -> int t
  val write: channel -> string -> int -> int -> unit t
end

module PacketStream : functor(IO: IO) -> sig
  type stream
  val make: IO.channel -> stream
  val recv: stream -> (t, string) result IO.t
  val send: stream -> t -> unit IO.t
end

val marshal : t -> string
val get_tid : t -> int32
val get_ty : t -> Op.t
val get_data : t -> string
val get_rid : t -> int32

val create : int32 -> int32 -> Op.t -> string -> t

module Token : sig
  type t
  (** A token is associated with every watch and returned in the
      callback. *)

  val to_debug_string: t -> string
  (** [to_string token] is a debug-printable version of [token]. *)

  val to_user_string: t -> string
  (** [to_user_string token] is the user-supplied part of [token]. *)

  val unmarshal: string -> t
  (** [of_string str_rep] is the token resulting from the
      unmarshalling of [str_rep]. *)

  val marshal: t -> string
  (** [to_string token] is the marshalled representation of [token]. *)
end

module Path : sig
  module Element : sig
    type t with sexp
    (** an element of a path *)

    exception Invalid_char of char

    val of_string: string -> t
    (** [of_string x] returns a [t] which corresponds to [x], or
        raises Invalid_char *)

    val to_string: t -> string
    (** [to_string t] returns a string which corresponds to [t] *)
  end

  type t with sexp
  (** a sequence of elements representing a 'path' from one node
      in the store down to another *)

  val empty: t
  (** the empty path *)

  exception Invalid_path of string * string
  (** [Invalid_path (path, reason)] indicates that [path] is invalid
      because [reason] *)

  val of_string: string -> t
  (** [of_string x] returns the [t] associated with [x], or raises
      Invalid_path *)

  val to_list: t -> Element.t list
  (** [to_list t] returns [t] as a list of elements *)

  val to_string: t -> string
  (** [to_string t] returns [t] as a string *)

  val to_string_list: t -> string list
  (** [to_string_list t] returns [t] as a string list *)

  val of_string_list: string list -> t
  (** [of_string_list x] parses [x] and returns a [t] *)

  val dirname: t -> t
  (** [dirname t]: returns the parent path of [t], or [t] itself if there is
      no parent, cf Filename.dirname *)

  val basename: t -> Element.t
  (** [basename t]: returns the final element of [t], cf Filename.basename *)

  val walk: (Element.t -> 'a -> 'a) -> t -> 'a -> 'a
  (** [walk f t]: folds [f] across each path element of [t] in order *)

  val fold: (t -> 'a -> 'a) -> t -> 'a -> 'a
  (** [fold f t initial]: folds [f] across each prefix sub-path of [t] in
      order of increasing length *)

  val iter: (t -> unit) -> t -> unit
  (** [iter f t]: applies every prefix sub-path of [t] to [f] in order of
      increasing length *)

  val common_prefix: t -> t -> t
  (** [common_prefix a b] returns the common prefix of [a] and [b] *)
end

module Name : sig
  type predefined =
  | IntroduceDomain
  | ReleaseDomain
  with sexp

  type t =
  | Predefined of predefined
  | Absolute of Path.t
  | Relative of Path.t
  with sexp
  (** a Name.t refers to something which can be watched, read or
      written via the protocol. *)

  val of_string: string -> t
  (** [of_string x] converts string [x] into a [t], or raises Invalid_path *)

  val to_string: t -> string
  (** [to_string t] converts [t] into a string *)

  val is_relative: t -> bool
  (** [is_relative t] is true if [t] is relative to a connection's directory *)

  val resolve: t -> t -> t
  (** [resolve t relative_to] interprets [t] relative to directory [relative_to].
      If [t] is relative and [relative_to] absolute, the result is absolute.
      In all other cases [t] is returned as-is. *)

  val relative: t -> t -> t
  (** [relative t base]: if [t] and [base] are absolute and [base] is a prefix
      of [t], return a relative path which refers to [t] when resolved 
      relative to [base]. *)

  val to_path: t -> Path.t
  (** [to_path t]: if [t] is an Absolute or Relative path, return it. Otherwise
      raise Invalid_path *)
end

module Response : sig
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

  val ty_of_payload: payload -> Op.t

  val marshal: payload -> int32 -> int32 -> t
end

module Request : sig

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

  val ty_of_payload: payload -> Op.t

  val parse: t -> payload option
  val marshal: payload -> int32 -> int32 -> t
end

module Unmarshal : sig
  val string : t -> string option
  val list : t -> string list option
  val acl : t -> ACL.t option
  val int : t -> int option
  val int32 : t -> int32 option
  val unit : t -> unit option
  val ok : t -> unit option
end

exception Enoent of string (** Raised when a named key does not exist. *)
exception Eagain           (** Raised when a transaction must be repeated. *)
exception Invalid
exception Error of string  (** Generic catch-all error. *)

val response: string -> t -> t -> (t -> 'a option) -> 'a
(** [response debug_hint sent received unmarshal] returns the
    [unmarshal]led response corresponding to the [received] packet
    relative to the [sent] packet. *)
