(*
 * Copyright (c) 2010 http://github.com/barko 00336ea19fcb53de187740c490f764f4
 * Copyright (c) 2011 Anil Madhavapeddy <anil@recoil.org>
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

module Lwt = struct end

let lwt_sequence_add_l s seq =
  let (_:'a Lwt_dllist.node) = Lwt_dllist.add_l s seq in
  ()

(* A bounded queue to receive data segments and let readers block on
   receiving them. Also supports a monitor that is informed when the
   queue size changes *)
module Rx = struct

 (* TODO: check that flow control works on the rx side - ie if the application
    stops taking data the window closes so the other side stops sending *)

  type t = {
    q: Cstruct.t option Lwt_dllist.t;
    wnd: Window.t;
    writers: unit Eio.Promise.u Lwt_dllist.t;
    readers: Cstruct.t option Eio.Promise.u Lwt_dllist.t;
    mutable watcher: int32 Eio.Stream.t option;
    mutable max_size: int32;
    mutable cur_size: int32;
  }

  let create ~max_size ~wnd =
    let q = Lwt_dllist.create () in
    let writers = Lwt_dllist.create () in
    let readers = Lwt_dllist.create () in
    let watcher = None in
    let cur_size = 0l in
    { q; wnd; writers; readers; max_size; cur_size; watcher }

  let notify_size_watcher t =
    let rx_wnd = max 0l (Int32.sub t.max_size t.cur_size) in
    Window.set_rx_wnd t.wnd rx_wnd;
    match t.watcher with
    | None   -> ()
    | Some w -> Eio.Stream.add w t.cur_size

  let seglen s =
    match s with
    | None -> 0
    | Some b -> Cstruct.length b

  let add_r t s =
    assert ((Domain.self () :> int) = 0);
    if t.cur_size > t.max_size then
      let th, u = Eio.Promise.create ~label:"User_buffer.add_r" () in
      let _node = Lwt_dllist.add_r u t.writers in
      
      (*Lwt.on_cancel th (fun _ -> Lwt_dllist.remove node);*)

      (* Update size before blocking, which may push cur_size above max_size *)
      t.cur_size <- Int32.(add t.cur_size (of_int (seglen s)));
      notify_size_watcher t;
      Eio.Promise.await th;
      ignore(Lwt_dllist.add_r s t.q);
      ()
    else match Lwt_dllist.take_opt_l t.readers with
      | None ->
        t.cur_size <- Int32.(add t.cur_size (of_int (seglen s)));
        ignore(Lwt_dllist.add_r s t.q);
        notify_size_watcher t
      | Some u ->
        (Eio.Promise.resolve u s)


  let label = "User_buffer.take_l"

  let take_l t =
    if Lwt_dllist.is_empty t.q then begin
      let th,u = Eio.Promise.create ~label () in
      let _node = Lwt_dllist.add_r u t.readers in
      (*Lwt.on_cancel th (fun _ -> Lwt_dllist.remove node);*)
      Eio.Promise.await th
    end else begin
      let s = Lwt_dllist.take_l t.q in
      t.cur_size <- Int32.(sub t.cur_size (of_int (seglen s)));
      notify_size_watcher t;
      if t.cur_size < t.max_size then begin
        match Lwt_dllist.take_opt_l t.writers with
        |None -> ()
        |Some w -> Eio.Promise.resolve w ()
      end;
      s
    end

  let cur_size t = t.cur_size
  let max_size t = t.max_size

  let monitor t mvar =
    t.watcher <- Some mvar

end

(* The transmit queue simply advertises how much data is allowed to be
   written, and a wakener for when it is full. It is up to the application
   to decide how to throttle or breakup its data production with this
   information.
*)
module Tx(Clock:Mirage_clock.MCLOCK) = struct

  module TXS = Segment.Tx(Clock)

  type t = {
    wnd: Window.t;
    writers: unit Eio.Promise.u Lwt_dllist.t;
    txq: TXS.t;
    buffer: Cstruct.t Lwt_dllist.t;
    max_size: int32;
    mutable bufbytes: int32;
  }

  let create ~max_size ~wnd ~txq =
    let buffer = Lwt_dllist.create () in
    let writers = Lwt_dllist.create () in
    let bufbytes = 0l in
    { wnd; writers; txq; buffer; max_size; bufbytes }

  let len data =
    Int32.of_int (Cstruct.length data)

  let lenv datav =
    match datav with
    |[] -> 0l
    |[d] -> Int32.of_int (Cstruct.length d)
    |ds -> Int32.of_int (List.fold_left (fun a b -> Cstruct.length b + a) 0 ds)

  (* Check how many bytes are available to write to output buffer *)
  let available t =
    let a = Int32.sub t.max_size t.bufbytes in
    match a < (Int32.of_int (Window.tx_mss t.wnd)) with
    | true -> 0l
    | false -> a

  (* Check how many bytes are available to write to wire *)
  let available_cwnd t =
    Window.tx_available t.wnd

  (* Wait until at least sz bytes are available in the window *)
  let rec wait_for t sz =
    if (available t) >= sz then begin
      ()
    end
    else begin
      let th,u = Eio.Promise.create ~label:"User_buffer.wait_for" () in
      let _node = Lwt_dllist.add_r u t.writers in
      (*Lwt.on_cancel th (fun _ -> Lwt_dllist.remove node);*)
      Eio.Promise.await th;
      wait_for t sz
    end

  let compactbufs bl = Cstruct.concat bl

  (* Wait until the user buffer is flushed *)
  let rec wait_for_flushed t =
    if Lwt_dllist.is_empty t.buffer then begin
      ()
    end
    else begin
      let th,u = Eio.Promise.create ~label:"User_buffer.wait_for_flushed" () in
      let _node = Lwt_dllist.add_r u t.writers in
      (*Lwt.on_cancel th (fun _ -> Lwt_dllist.remove node);*)
      Eio.Promise.await th;
      wait_for_flushed t
    end

  let rec clear_buffer t =
    let rec addon_more curr_data l =
      match Lwt_dllist.take_opt_l t.buffer with
      | None -> List.rev curr_data
      | Some s ->
        let s_len = len s in
        match s_len > l with
        | true ->
          lwt_sequence_add_l s t.buffer;
          List.rev curr_data
        | false ->
          t.bufbytes <- Int32.sub t.bufbytes s_len;
          addon_more (s::curr_data) (Int32.sub l s_len)
    in
    let get_pkt_to_send () =
      let avail_len = min (available_cwnd t) (Int32.of_int (Window.tx_mss t.wnd)) in
      let s = Lwt_dllist.take_l t.buffer in
      let s_len = len s in
      match s_len > avail_len with
      | true ->  begin
          match avail_len with
          |0l -> (* return pkt to buffer *)
            lwt_sequence_add_l s t.buffer;
            None
          |_ -> (* split buffer into a partial write *)
            let to_send,remaining = Cstruct.split s (Int32.to_int avail_len) in
            (* queue remaining view *)
            lwt_sequence_add_l remaining t.buffer;
            t.bufbytes <- Int32.sub t.bufbytes avail_len;
            Some [to_send]
        end
      | false ->
        match s_len < avail_len with
        | true ->
          t.bufbytes <- Int32.sub t.bufbytes s_len;
          Some (addon_more (s::[]) (Int32.sub avail_len s_len))
        | false ->
          t.bufbytes <- Int32.sub t.bufbytes s_len;
          Some [s]
    in
    match Lwt_dllist.is_empty t.buffer with
    | true -> ()
    | false ->
      match get_pkt_to_send () with
      | None -> ()
      | Some pkt ->
        let b = compactbufs pkt in
        TXS.output ~flags:Segment.Psh t.txq b;
        clear_buffer t

  (* Chunk up the segments into MSS max for transmission *)
  let transmit_segments ~mss ~txq datav =
    let transmit acc =
      let b = compactbufs (List.rev acc) in
      TXS.output ~flags:Segment.Psh txq b
    in
    let rec chunk datav acc =
      match datav with
      |[] -> begin
          match acc with
          |[] -> ()
          |_ -> transmit acc
        end
      |hd::tl ->
        let curlen = Cstruct.lenv acc in
        let tlen = Cstruct.length hd + curlen in
        if tlen > mss then begin
          let a,b = Cstruct.split hd (mss - curlen) in
          transmit (a::acc);
          chunk (b::tl) []
        end else
          chunk tl (hd::acc)
    in
    chunk datav []

  let write t datav =
    let l = lenv datav in
    let mss = Int32.of_int (Window.tx_mss t.wnd) in
    match Lwt_dllist.is_empty t.buffer &&
          (l = mss || not (Window.tx_inflight t.wnd)) with
    | false ->
      t.bufbytes <- Int32.add t.bufbytes l;
      List.iter (fun data -> ignore(Lwt_dllist.add_r data t.buffer)) datav;
      if t.bufbytes < mss then
        ()
      else
        clear_buffer t
    | true ->
      let avail_len = available_cwnd t in
      match avail_len < l with
      | true ->
        t.bufbytes <- Int32.add t.bufbytes l;
        List.iter (fun data -> ignore(Lwt_dllist.add_r data t.buffer)) datav;
        ()
      | false ->
        let max_size = Window.tx_mss t.wnd in
        transmit_segments ~mss:max_size ~txq:t.txq datav

  let write_nodelay t datav =
    let l = lenv datav in
    match Lwt_dllist.is_empty t.buffer with
    | false ->
      t.bufbytes <- Int32.add t.bufbytes l;
      List.iter (fun data -> ignore(Lwt_dllist.add_r data t.buffer)) datav;
      ()
    | true ->
      let avail_len = available_cwnd t in
      match avail_len < l with
      | true ->
        t.bufbytes <- Int32.add t.bufbytes l;
        List.iter (fun data -> ignore(Lwt_dllist.add_r data t.buffer)) datav;
        ()
      | false ->
        let max_size = Window.tx_mss t.wnd in
        transmit_segments ~mss:max_size ~txq:t.txq datav


  let inform_app t =
    match Lwt_dllist.take_opt_l t.writers with
    | None   -> ()
    | Some w ->
      Eio.Promise.resolve w ();
      (* TODO: check if this should wake all writers not just one *)
      ()

  (* Indicate that more bytes are available for waiting writers.
     Note that sz does not take window scaling into account, and so
     should be passed as unscaled (i.e. from the wire) here.
     Window will internally scale it up. *)
  let free t _sz =
    clear_buffer t;
    inform_app t

  let reset t =
    (* FIXME: duplicated code with Segment.reset_seq *)
    let rec reset_seq segs =
      match Lwt_dllist.take_opt_l segs with
      | None   -> ()
      | Some _ -> reset_seq segs
    in
    reset_seq t.buffer;
    inform_app t

end
