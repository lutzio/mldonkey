(* Copyright 2001, 2002 b8_bavard, b8_fee_carabine, INRIA *)
(*
    This file is part of mldonkey.

    mldonkey is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    mldonkey is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with mldonkey; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*)
type event =
    WRITE_DONE
  | CAN_REFILL
  | BUFFER_OVERFLOW
  | READ_DONE of int
  | BASIC_EVENT of BasicSocket.event

and buf = {
  mutable buf : string;
  mutable pos : int;
  mutable len : int;
  mutable max_buf_size : int;
  } 
  
type t

type bandwidth_controler
  
and handler = t -> event -> unit

val sock: t -> BasicSocket.t
val create : Unix.file_descr -> handler -> t
val create_simple : Unix.file_descr -> t
val create_blocking : Unix.file_descr -> handler -> t
val buf : t -> buf
val set_reader : t -> (t -> int -> unit) -> unit
val buf_used : t -> int -> unit
val set_handler : t -> event -> (t -> unit) -> unit
val set_refill : t -> (t -> unit) -> unit
val write: t -> string -> int -> int -> unit
val write_string: t -> string -> unit
val connect: Unix.inet_addr -> int -> handler -> t
val close : t -> string -> unit
val shutdown : t -> string -> unit
val error: t -> string
val tcp_handler: t -> BasicSocket.t -> BasicSocket.event -> unit
val set_closer : t -> (t -> string -> unit) -> unit
val nread : t -> int
val set_max_write_buffer : t -> int -> unit  
val can_write : t -> bool  
val set_monitored : t -> unit
  
val close_after_write : t -> unit

val create_read_bandwidth_controler : int -> bandwidth_controler
val create_write_bandwidth_controler : int -> bandwidth_controler
val set_read_controler : t -> bandwidth_controler -> unit
val set_write_controler : t -> bandwidth_controler -> unit
val change_rate : bandwidth_controler -> int -> unit
  
val exec_command : string -> string array -> handler -> t * t
  
val my_ip : t -> Ip.t