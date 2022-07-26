(*
 * Copyright (c) 2010 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)


(* General signature for all the ack modules *)
module type M = sig
  type t

  (* ack: put mvar to trigger the transmission of an ack *)
  val t : sw:Eio.Switch.t -> clock:Eio.Time.clock -> send_ack:Sequence.t Eio.Stream.t -> last:Sequence.t -> t

  (* called when new data is received *)
  val receive: t -> Sequence.t -> unit

  (* called when new data is received *)
  val pushack: t -> Sequence.t -> unit

  (* called when an ack is transmitted from elsewhere *)
  val transmit: t -> Sequence.t -> unit
end

(* Transmit ACKs immediately, the dumbest (and simplest) way *)
module Immediate : M = struct

  type t = {
    mutable send_ack: Sequence.t Eio.Stream.t;
    mutable pushpending: bool;
  }

  let t ~sw:_ ~clock:_ ~send_ack ~last:_ =
    let pushpending = false in
    {send_ack; pushpending}

  let pushack t ack_number =
    t.pushpending <- true;
    Eio.Stream.add t.send_ack ack_number

  let receive t ack_number =
    match t.pushpending with
    | true  -> ()
    | false -> pushack t ack_number

  let transmit t _ =
    t.pushpending <- false;
    ()
end


(* Delayed ACKs *)
module Delayed : M = struct

  module TT = Tcptimer

  type delayed_r = {
    send_ack: Sequence.t Eio.Stream.t;
    mutable delayedack: Sequence.t;
    mutable delayed: bool;
    mutable pushpending: bool;
  }

  type t = {
    r: delayed_r;
    timer: Tcptimer.t;
  }

  let transmitacknow r ack_number =
    Eio.Stream.add r.send_ack ack_number

  let transmitack r ack_number =
    match r.pushpending with
    | true  -> ()
    | false ->
      r.pushpending <- true;
      transmitacknow r ack_number

  let ontimer r s  =
    match r.delayed with
    | false -> Tcptimer.Stoptimer
    | true  ->
      match r.delayedack = s with
      | false ->
        (Tcptimer.Continue r.delayedack)
      | true ->
        r.delayed <- false;
        transmitack r s;
        Tcptimer.Stoptimer

  let t ~sw ~clock ~send_ack ~last : t =
    let pushpending = false in
    let delayed = false in
    let delayedack = last in
    let r = {send_ack; delayedack; delayed; pushpending} in
    let expire = ontimer r in
    let period_ns = Duration.of_ms 100 in
    let timer = TT.t ~sw ~clock ~period_ns ~expire in
    {r; timer}


  (* Advance the received ACK count *)
  let receive t ack_number =
    match t.r.delayed with
    | true ->
      t.r.delayed <- false;
      transmitack t.r ack_number
    | false ->
      t.r.delayed <- true;
      t.r.delayedack <- ack_number;
      TT.restart t.timer ack_number


  (* Force out an ACK *)
  let pushack t ack_number =
    transmitacknow t.r ack_number


  (* Indicate that an ACK has been transmitted *)
  let transmit t _ =
    t.r.delayed <- false;
    t.r.pushpending <- false;
    ()

end
