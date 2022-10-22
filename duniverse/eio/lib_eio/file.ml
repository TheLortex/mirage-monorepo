(** A file opened for reading. *)
class virtual ro = object (_ : <Generic.t; Flow.source; ..>)
  method probe _ = None
  method read_methods = []
  method virtual pread : file_offset:Optint.Int63.t -> Cstruct.t list -> int
end

(** A file opened for reading and writing. *)
class virtual rw = object (_ : <Generic.t; Flow.source; Flow.sink; ..>)
  inherit ro
  method virtual pwrite : file_offset:Optint.Int63.t -> Cstruct.t list -> int
end

(** [pread t ~file_offset bufs] performs a single read of [t] at [file_offset] into [bufs].

    It returns the number of bytes read, which may be less than the space in [bufs],
    even if more bytes are available. Use {!pread_exact} instead if you require
    the buffer to be filled.

    To read at the current offset, use {!Flow.read} instead. *)
let pread (t : #ro) ~file_offset bufs =
  let got = t#pread ~file_offset bufs in
  assert (got > 0 && got <= Cstruct.lenv bufs);
  got

(** [pread_exact t ~file_offset bufs] reads from [t] into [bufs] until [bufs] is full.

    @raise End_of_file if the buffer could not be filled. *)
let rec pread_exact (t : #ro) ~file_offset bufs =
  if Cstruct.lenv bufs > 0 then (
    let got = t#pread ~file_offset bufs in
    let file_offset = Optint.Int63.add file_offset (Optint.Int63.of_int got) in
    pread_exact t ~file_offset (Cstruct.shiftv bufs got)
  )

(** [pwrite_single t ~file_offset bufs] performs a single write operation, writing
    data from [bufs] to location [file_offset] in [t].

    It returns the number of bytes written, which may be less than the length of [bufs].
    In most cases, you will want to use {!pwrite_all} instead. *)
let pwrite_single (t : #rw) ~file_offset bufs =
  let got = t#pwrite ~file_offset bufs in
  assert (got > 0 && got <= Cstruct.lenv bufs);
  got

(** [pwrite_all t ~file_offset bufs] writes all the data in [bufs] to location [file_offset] in [t]. *)
let rec pwrite_all (t : #rw) ~file_offset bufs =
  if Cstruct.lenv bufs > 0 then (
    let got = t#pwrite ~file_offset bufs in
    let file_offset = Optint.Int63.add file_offset (Optint.Int63.of_int got) in
    pwrite_all t ~file_offset (Cstruct.shiftv bufs got)
  )
