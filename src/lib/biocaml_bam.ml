open Biocaml_internal_pervasives

type raw_alignment = {
  qname : string;
  flag : int;
  ref_id: int;
  (* rname : string; *)
  pos : int;
  mapq : int;
  bin: int;
  cigar : string;
  next_ref_id : int;
  pnext : int;
  tlen : int;
  seq : string;
  qual : int array;
  optional : string;
}

type raw_item =
[ `alignment of raw_alignment
| `header of string
| `reference_information of (string * int) array ]

type parse_optional_error = [
| `wrong_auxiliary_data of
      [ `array_size of int
      | `null_terminated_hexarray
      | `null_terminated_string
      | `wrong_int32 of string
      | `out_of_bounds
      | `unknown_type of char ] * string
]
type raw_parsing_error = [
| `read_name_not_null_terminated of string
| `reference_information_name_not_null_terminated of string
| `reference_information_overflow of int * string
| `wrong_magic_number of string
| `wrong_int32 of string
]
open Result

let of_result r = match r with Ok o -> `output o | Error e -> `error e

let string_of_raw_parsing_error e =
  match e with
  | `wrong_int32 s ->
    sprintf "wrong_int32 %S" (String.sub s 0 4)
  | `read_name_not_null_terminated s ->
    sprintf "read_name_not_null_terminated %s" s
  | `reference_information_name_not_null_terminated s ->
    sprintf "reference_information_name_not_null_terminated %s" s
  | `reference_information_overflow (len, buff) ->
    sprintf "reference_information_overflow %d" len
  | `wrong_auxiliary_data (wad, s) ->
    sprintf "wrong_auxiliary_data (%s, %S)" s
      (match wad with
      | `wrong_int32 s ->
        sprintf "wrong_int32 %S" (String.sub s 0 4)
      | `array_size d -> sprintf "array_size %d" d
      | `null_terminated_hexarray -> "null_terminated_hexarray"
      | `null_terminated_string -> "null_terminated_string"
      | `out_of_bounds -> "out_of_bounds"
      | `unknown_type c -> sprintf "unknown_type '%c'" c)
  | `wrong_cigar s -> sprintf "wrong_cigar %s" s
  | `wrong_magic_number s -> sprintf "wrong_magic_number %s" s

let dbg fmt = Debug.make "BAM" fmt

let check b e = if b then return () else fail e

let signed_int ~buf ~pos =
  let b1 = Char.to_int buf.[pos + 0] |! Int32.of_int_exn in
  let b2 = Char.to_int buf.[pos + 1] |! Int32.of_int_exn in
  let b3 = Char.to_int buf.[pos + 2] |! Int32.of_int_exn in
  let b4 = Char.to_int buf.[pos + 3] |! Int32.of_int_exn in
  let i32 =
    Int32.(bit_or  b1
             (bit_or (shift_left b2 8)
                (bit_or (shift_left b3 16)
                   (shift_left b4 24)))) in
  try return (Int32.to_int_exn i32) with e -> fail (`wrong_int32 buf)
    
let parse_header buf =
  check (String.length buf >= 12) `no
  >>= fun () ->
  check (String.sub buf 0 4 = "BAM\001")
    (`wrong_magic_number (String.sub buf 0 4))
  >>= fun () ->
  signed_int ~buf ~pos:4 >>= fun length ->
  dbg "header length: %d" length;
  check (String.length buf >= 4 + 4 + length + 4) `no
  >>= fun () ->
  let sam_header = String.sub buf 8 length in
  dbg "sam header: %S" sam_header;
  signed_int ~buf ~pos:(8 + length)
  >>= fun nb_refs ->
  dbg "nb refs: %d" nb_refs;
  return (`header sam_header, nb_refs, 4 + 4 + length + 4)

let parse_reference_information_item buf pos =
  check (String.length buf - pos >= 4) `no >>= fun () ->
  signed_int ~buf ~pos
  >>= fun l_name ->
  dbg "l_name: %d" l_name;
  check (String.length buf - pos >= 4 + l_name + 4) `no >>= fun () ->
  let name = String.sub buf (pos + 4) (l_name - 1) in
  dbg "name: %S" name;
  check (buf.[pos + 4 + l_name - 1] = '\000')
    (`reference_information_name_not_null_terminated (String.sub buf 4 l_name))
  >>= fun () ->
  signed_int ~buf ~pos:(pos + 4 + l_name)
  >>= fun l_ref ->
  return (4 + l_name + 4, name, l_ref)

let parse_reference_information buf nb =
  let bytes_read = ref 0 in
  let error = ref None in
  try
    let refinfo =
      (Array.init nb (fun _ ->
        match parse_reference_information_item buf !bytes_read with
        | Ok (read, name, lref) ->
          bytes_read := !bytes_read + read;
          dbg "parse_reference_information_item: %d %s %d" read name lref;
          (name, lref)
        | Error `no -> failwith "NO"
        | Error other -> error := Some other; failwith "ERROR")) in
    `reference_information (refinfo, !bytes_read)
  with
  | Failure "NO" -> `no
  | Failure "ERROR" -> `error Option.(value_exn !error)



let parse_alignment buf =
  check (String.length buf >= 4 * 9) `no >>= fun () ->
  let uint16 pos =
    Binary_packing.unpack_unsigned_8 ~buf ~pos +
      Binary_packing.unpack_unsigned_8 ~buf ~pos:(pos + 1) lsl 7 in
  let uint8 pos = Binary_packing.unpack_unsigned_8 ~buf ~pos in
  signed_int ~buf ~pos:0 >>= fun block_size ->
  signed_int ~buf ~pos: 4
  >>= fun  ref_id ->
  signed_int ~buf ~pos: 8
  >>= fun  pos ->
  (* bin mq nl would be packed in a little-endian uint32, so we unpack
     its contents "in reverse order": *)
  let l_read_name = uint8 12 in
  let mapq = uint8 13 in
  let bin = uint16 14 in
  (* idem for flag_nc *)
  let n_cigar_op = uint16 16 in
  let flag = uint16 18 in
  (* back to "normal" *)
  signed_int ~buf ~pos: 20
  >>= fun  l_seq ->
  signed_int ~buf ~pos:24
  >>= fun  next_ref_id ->
  signed_int ~buf ~pos:28
  >>= fun  next_pos ->
  signed_int ~buf ~pos:32
  >>= fun  tlen ->
  dbg " block_size: %d ref_id: %d pos: %d l_read_name: %d mapq: %d
  bin: %d n_cigar_op: %d flag: %d l_seq: %d next_ref_id: %d next_pos: %d tlen: %d"
    block_size ref_id pos l_read_name mapq bin n_cigar_op flag l_seq next_ref_id
    next_pos tlen;

  check (String.length buf >= block_size + 4) `no
    (* (4 * 9) + l_read_name + (n_cigar_op * 4) + ((l_seq + 1) / 2) + l_seq) *)
  >>= fun () ->
  let qname = String.sub buf 36 (l_read_name - 1) in
  check (buf.[36 + l_read_name - 1] = '\000')
    (`read_name_not_null_terminated (String.sub buf 36 l_read_name))
  >>= fun () ->
  (* dbg "qname: %S" qname; *)
  let cigar_buf = String.sub buf (36 + l_read_name) (n_cigar_op * 4) in
  let seq = String.make l_seq '*' in
  let letter  = function
    | 0  -> '='
    | 1  -> 'A'
    | 2  -> 'C'
    | 3  -> 'M'
    | 4  -> 'G'
    | 5  -> 'R'
    | 6  -> 'S'
    | 7  -> 'V'
    | 8  -> 'T'
    | 9  -> 'W'
    | 10 -> 'Y'
    | 11 -> 'H'
    | 12 -> 'K'
    | 13 -> 'D'
    | 14 -> 'B'
    | 15 -> 'N'
    | l -> failwithf "letter not in [0, 15]: %d" l () in
  for i = 0 to ((l_seq + 1) / 2) - 1 do
    (* dbg "i: %d" i; *)
    let byte = uint8 ((4 * 9) + l_read_name + (n_cigar_op * 4) + i) in
    (* dbg "byte: %d" byte; *)
    seq.[2 * i] <- letter ((byte land 0xf0) lsr 4);
    if 2 * i + 1 < l_seq then
      seq.[2 * i + 1] <- letter (byte land 0x0f);
  done;
  (* dbg "seq: %S" seq; *)
  let qual =
    Array.init l_seq (fun i ->
      Char.to_int
        buf.[(4 * 9) + l_read_name + (n_cigar_op * 4) + ((l_seq + 1) / 2) + i]
    ) in
  let aux_data =
    let offset =
      (4 * 9) + l_read_name + (n_cigar_op * 4) + ((l_seq + 1) / 2) + l_seq in
    String.sub buf offset (block_size + 4 - offset) in
  let alignment = {
    qname;

    flag;
    ref_id;
    (* rname = qname; *)
    pos;
    mapq;
    bin;
    cigar = cigar_buf ;
    next_ref_id;
    pnext = next_pos;
    tlen;
    seq;
    qual;
    optional = aux_data } in
  return (`alignment alignment, block_size + 4)

let uncompressed_bam_parser () =
  let in_buffer = Buffer.create 42 in
  let state = ref `header in
  let next stopped =
    let buffered = Buffer.contents in_buffer in
    let len = String.length buffered in
    Buffer.clear in_buffer;
    dbg "uncompressed_bam_parser: len: %d" len;
    begin match len with
    | 0 -> if stopped then `end_of_stream else `not_ready
    | _ ->
      begin match !state with
      | `header ->
        begin match parse_header buffered with
        | Ok (o, nbrefs, nbread) ->
          state := `reference_information nbrefs;
          Buffer.add_substring in_buffer buffered nbread (len - nbread);
          `output o
        | Error `no ->
          dbg "rebuffering %d bytes" String.(length buffered);
          Buffer.add_string in_buffer buffered; `not_ready
        | Error e -> `error e
        end
      | `reference_information nb ->
        begin match parse_reference_information buffered nb with
        | `no ->
          dbg "(ri) rebuffering %d bytes" String.(length buffered);
          if len > 50000
          then `error (`reference_information_overflow (len, buffered))
          else begin
            Buffer.add_string in_buffer buffered;
            `not_ready
          end
        | `error  e -> `error e
        | `reference_information (refinfo, nbread) ->
          Buffer.add_substring in_buffer buffered nbread (len - nbread);
          state := `alignments refinfo;
          `output (`reference_information refinfo)
        end
      | `alignments refinfo ->
        begin match parse_alignment buffered with
        | Ok (o, nbread) ->
          dbg "len: %d nbread: %d" len nbread;
          Buffer.add_substring in_buffer buffered nbread (len - nbread);
          `output (o : raw_item)
        | Error `no ->
          dbg "(al) rebuffering %d bytes" String.(length buffered);
          Buffer.add_string in_buffer buffered; `not_ready
        | Error  e -> `error e
        end
      end
    end
  in
  Biocaml_transform.make_stoppable ()
    ~feed:(fun string -> Buffer.add_string in_buffer string;) ~next

let raw_parser ?zlib_buffer_size () =
  Biocaml_transform.(
    on_error
      ~f:(function
      | `left l -> `unzip l
      | `right r ->
        match r with
        | `no -> failwith "got `right `no"
        | #raw_parsing_error as a -> `bam a)
      (compose
       (Biocaml_zip.unzip ~format:`gzip ?zlib_buffer_size ())
       (uncompressed_bam_parser ())))

let parse_optional ?(pos=0) ?len buf =
  let len =
    match len with Some s -> s | None -> String.length buf in
  let uint16 pos =
    Binary_packing.unpack_unsigned_8 ~buf ~pos +
      Binary_packing.unpack_unsigned_8 ~buf ~pos:(pos + 1) lsl 7 in
  let from () = String.sub buf pos len in
  dbg "from: %S" (from ());
  let rec build ofs acc =
    let error e = fail (`wrong_auxiliary_data (e, from ())) in
    if ofs >= len then return acc
    else (
      if ofs + 2 >= len then error `out_of_bounds
      else (
        let tag = String.sub buf ofs 2 in
        let typ = buf.[ofs + 2] in
        let check_size_and_return n r =
          if ofs + 2 + n >= len then error `out_of_bounds
          else return (r, n) in
        let parse_cCsSiIf pos typ =
          begin match typ with
          | 'i' ->
            signed_int ~buf ~pos >>= fun v ->
            check_size_and_return 4 (`int v)
          | 'A' -> check_size_and_return 1 (`char buf.[pos])
          | 'c' | 'C' -> check_size_and_return 1 (`int (Char.to_int buf.[pos]))
          | 's' ->
            check_size_and_return 2 (`int (
              Binary_packing.unpack_signed_16
                ~byte_order:`Little_endian ~buf ~pos))
          | 'S' -> check_size_and_return 2 (`int (uint16 pos))
          | 'f' ->
            let f =
              Binary_packing.unpack_signed_32
                ~byte_order:`Little_endian ~buf ~pos |! Int32.float_of_bits in
            check_size_and_return 4 (`float f)
          | _ -> error (`unknown_type typ)
          end
        in
        let pos = ofs + 3 in
        begin match typ with
        | 'A' -> check_size_and_return 1 (`char buf.[pos])
        | 'Z' ->
          begin match String.index_from buf pos '\000' with
          | Some e -> return (`string String.(slice buf pos e), e - pos + 1)
          | None -> error `null_terminated_string
          end
        | 'H' ->
          begin match String.index_from buf pos '\000' with
          | Some e -> return (`string String.(slice buf pos e), e - pos + 1)
          | None -> error `null_terminated_hexarray
          end
        | 'B' ->
          check_size_and_return 1 buf.[pos] >>= fun (array_type, _) ->
          signed_int ~buf ~pos:(pos + 1) >>= fun i32 ->
          check_size_and_return 4 i32 >>= fun (size, _) ->
          (if size > 4000 then error (`array_size size) else return ())
          >>= fun () ->
          let arr = Array.create size (`char 'B') in
          let rec loop p = function
            | 0 -> return p
            | n ->
              parse_cCsSiIf p array_type
              >>= fun (v, nb) ->
              arr.(size - n) <- v;
              loop (p + nb) (n - 1) in
          loop (pos + 5) size
          >>= fun newpos ->
          return (`array (array_type, arr), newpos - pos)
        | c -> parse_cCsSiIf pos c
        end
        >>= fun (v, nbread) ->
        build (ofs + 3 + nbread) ((tag, typ, v) :: acc)
      )
    )
  in
  match build pos [] with
  | Ok r -> return (List.rev r)
  | Error (`wrong_auxiliary_data e) -> fail (`wrong_auxiliary_data e)
  | Error (`wrong_int32 e) -> fail (`wrong_auxiliary_data (`wrong_int32 e, from ()))

type cigar_op = [
| `D of int
| `Eq of int
| `H of int
| `I of int
| `M of int
| `N of int
| `P of int
| `S of int
| `X of int ]

type parse_cigar_error = [
| `wrong_cigar of string
| `wrong_cigar_length of int ]

let parse_cigar ?(pos=0) ?len buf =
  let len =
    match len with Some s -> s | None -> String.length buf in
  begin match len mod 4 with
  | 0 -> return (len / 4)
  | n -> fail (`wrong_cigar_length len)
  end
  >>= fun n_cigar_op ->
  begin
    try
      return (Array.init n_cigar_op (fun i ->
        let open Int64 in
        let int64 =
          let int8 pos =
            Binary_packing.unpack_unsigned_8 ~buf ~pos |! Int64.of_int in
          int8 Int.(pos + i * 4)
          + shift_left (int8 Int.(pos + i * 4 + 1)) 8
          + shift_left (int8 Int.(pos + i * 4 + 2)) 16
          + shift_left (int8 Int.(pos + i * 4 + 3)) 24
        in
        let op_len = shift_right int64 4 |! Int64.to_int_exn in
        let op =
          match bit_and int64 0x0fL with
          | 0L -> `M op_len
          | 1L -> `I op_len
          | 2L -> `D op_len
          | 3L -> `N op_len
          | 4L -> `S op_len
          | 5L -> `H op_len
          | 6L -> `P op_len
          | 7L -> `Eq op_len
          | 8L -> `X op_len
          | any -> failwithf "OP:%Ld" any () in
        op))
    with
    | e ->
      fail (`wrong_cigar
               String.(sub buf pos (pos + n_cigar_op * 4)))
  end
  (* dbg "cigar: %s" (Array.to_list cigarray *)
                   (* |! List.map ~f:(fun (op, len) -> sprintf "%c:%d" op len) *)
                   (* |! String.concat ~sep:"; "); *)

let parse_sam_header h =
  let lines = String.split ~on:'\n' h |! List.filter ~f:((<>) "") in
  Result_list.while_ok lines (fun idx line ->
    dbg "parse_sam_header %d %s" idx line;
    Biocaml_sam.parse_header_line idx line
    >>= fun raw_sam ->
    begin match raw_sam with
    | `comment s -> return (`comment s)
    | `header ("HD", l) ->
      if idx <> 0
      then fail (`header_line_not_first idx)
      else Biocaml_sam.expand_header_line l
    | `header h -> return (`header h)
    end)

let expand_alignment refinfo raw =
  let {
    qname (* : string *); flag (* : int *); ref_id;
    pos (* : int *); mapq (* : int *); bin (* : int *); cigar (* : string *);
    next_ref_id (* : int *); pnext (* : int *); tlen (* : int *);
    seq (* : string *); qual (* : int array *); optional (* : string *);} = raw in
  let check c e = if c then return () else fail e in
  check (1 <= String.length qname && String.length qname <= 255)
    (`wrong_qname raw)
  >>= fun () ->
  check (0 <= flag && flag <= 65535) (`wrong_flag raw) >>= fun () ->
  let find_ref id =
    begin match id with
    | -1 -> return `none
    | other ->
      begin try return (`reference_sequence refinfo.(other))
        with e -> fail (`reference_sequence_not_found raw) end
    end in
  find_ref ref_id >>= fun reference_sequence ->
  check (-1 <= pos && pos <= 536870910) (`wrong_pos raw) >>= fun () ->
  check (0 <= mapq && mapq <= 255) (`wrong_mapq raw) >>= fun () ->
  parse_cigar cigar >>= fun cigar_operations ->
  find_ref next_ref_id >>= fun next_reference_sequence ->
  check (-1 <= pnext && pnext <= 536870910) (`wrong_pnext raw) >>= fun () ->
  check (-536870911 <= tlen && tlen <= 536870911) (`wrong_tlen raw)
  >>= fun () ->
  parse_optional optional >>= fun optional_content ->
  return (`alignment {
    Biocaml_sam.
    query_template_name = qname;
    flags = Biocaml_sam.Flags.of_int flag;
    reference_sequence;
    position = if pos = -1 then None else Some (pos + 1);
    mapping_quality =if mapq = 255 then None else Some mapq;
    cigar_operations;
    next_reference_sequence = next_reference_sequence;
    next_position = if pnext = -1 then None else Some (pnext + 1);
    template_length  = if tlen = 0 then None else Some tlen;
    sequence = `string seq;
    quality = Array.map qual ~f:Biocaml_phred_score.of_int_exn;
    optional_content;
  })


let item_parser () : (raw_item, Biocaml_sam.item, _) Biocaml_transform.t=
  let name = "bam_item_parser" in
  let raw_queue = Dequeue.create ~dummy:(`header "no") () in
  let raw_items_count = ref 0 in
  let header_items = ref [] in
  let reference_information = ref [| |] in
  let first_alignment = ref true in
  let rec next stopped =
    dbg "header_items: %d   raw_queue: %d  raw_items_count: %d"
      (List.length !header_items) (Dequeue.length raw_queue) !raw_items_count;
    begin match !header_items with
    | h :: t -> header_items := t; `output h
    | [] ->
      begin match Dequeue.is_empty raw_queue, stopped with
      | true, true ->`end_of_stream
      | true, false -> `not_ready
      | false, _ ->
        incr raw_items_count;
        begin match Dequeue.take_front_exn raw_queue with
        | `header s ->
          begin match parse_sam_header s with
          | Ok h -> header_items := h; next stopped
          | Error e -> `error e
          end
        | `reference_information ri ->
          let make_ref_info (s, i) = Biocaml_sam.reference_sequence s i in
          reference_information := Array.map ri ~f:make_ref_info;
          next stopped
        | `alignment a ->
          if !first_alignment then (
            first_alignment := false;
            Dequeue.push_front raw_queue (`alignment a);
            `output (`reference_sequence_dictionary !reference_information)
          ) else (
            expand_alignment !reference_information a |! of_result
          )
        end
      end
    end
  in
  Biocaml_transform.make_stoppable ~name ~feed:(Dequeue.push_back raw_queue) ()
    ~next

let downgrade_alignement al ref_dict =
  let module S = Biocaml_sam in
  let find_ref s =
    begin match Array.findi ref_dict (fun _ n -> n.S.ref_name = s) with
    | Some (i, _) -> return i
    | None -> fail (`reference_name_not_found (al, s))
    end
  in
    
  let qname = al.S.query_template_name in
  let flag = (al.S.flags :> int) in
  begin match al.S.reference_sequence with
  | `name s -> find_ref s
  | `none -> return (-1)
  | `reference_sequence rs -> find_ref rs.S.ref_name
  end
  >>= fun ref_id ->
  let pos = (Option.value ~default:0 al.S.position) - 1 in
  let mapq = Option.value ~default:(-1) al.S.mapping_quality in
  begin match al.S.sequence with
  | `string s -> return s
  | `none -> return ""
  | `reference -> fail (`cannot_get_sequence al)
  end
  >>= fun seq ->
  let bin =
    let beg = pos in
    let end_close (* open interval but then '--pos;' *) =
      pos + String.(length seq) in
    match beg, end_close with
    | b,e when b lsr 14 = e lsr 14 ->
      ((1 lsl 15) - 1) / 7  +  (beg lsr 14)
    | b,e when b lsr 17 = e lsr 17 ->
      ((1 lsl 12) - 1) / 7  +  (beg lsr 17)
    | b,e when b lsr 20 = e lsr 20 ->
      ((1 lsl 9) - 1) / 7  +  (beg lsr 20)
    | b,e when b lsr 23 = e lsr 23 ->
      ((1 lsl 6) - 1) / 7  +  (beg lsr 23)
    | b,e when b lsr 26 = e lsr 26 ->
      ((1 lsl 3) - 1) / 7  +  (beg lsr 26)
    | _ -> 0 in
  dbg "bin: %d" bin;
  let cigar =
    let buf = String.create (Array.length al.S.cigar_operations * 4) in
    let write ith i32 =
      let pos = ith * 4 in
      Binary_packing.pack_signed_32 ~byte_order:`Little_endian ~buf ~pos i32 in
    let open Int32 in
    let op c = of_int_exn (Char.to_int c) in
    Array.iteri al.S.cigar_operations ~f:(fun idx -> function
    | `D  i -> bit_or (op 'D') (of_int_exn i) |! write idx
    | `Eq i -> bit_or (op '=') (of_int_exn i) |! write idx
    | `H  i -> bit_or (op 'H') (of_int_exn i) |! write idx
    | `I  i -> bit_or (op 'I') (of_int_exn i) |! write idx
    | `M  i -> bit_or (op 'M') (of_int_exn i) |! write idx
    | `N  i -> bit_or (op 'N') (of_int_exn i) |! write idx
    | `P  i -> bit_or (op 'P') (of_int_exn i) |! write idx
    | `S  i -> bit_or (op 'S') (of_int_exn i) |! write idx
    | `X  i -> bit_or (op 'X') (of_int_exn i) |! write idx);
    buf
  in
  dbg "cigar: %S" cigar;
  begin match al.S.next_reference_sequence with
  | `qname -> find_ref qname
  | `none -> return (-1)
  | `name s -> find_ref s
  | `reference_sequence rs -> find_ref rs.S.ref_name
  end
  >>= fun next_ref_id ->
  let pnext = Option.value ~default:0 al.S.next_position - 1 in
  let tlen = Option.value ~default:0 al.S.template_length in
  let qual = Array.map al.S.quality ~f:Biocaml_phred_score.to_int in
  let optional =
    let rec content typ = function
      | `array (t, v) ->
        sprintf "%c%s" t (Array.map ~f:(content t) v |! String.concat_array ~sep:"")
      | `char c -> Char.to_string c
      | `float f ->
        let bits = Int32.bits_of_float f in
        let buf = String.create 4 in
        Binary_packing.pack_signed_32
          ~byte_order:`Little_endian bits ~buf ~pos:0;
        buf
      | `int i ->
        begin match typ with
        | 'c' | 'C' -> 
          let buf = String.create 1 in
          Binary_packing.pack_unsigned_8 (0xff land i) ~buf ~pos:0;
          buf
        | 's' | 'S' ->
          let buf = String.create 2 in
          Binary_packing.pack_signed_16 (0xffff land i)
            ~byte_order:`Little_endian ~buf ~pos:0;
          buf
        | _ -> 
          let buf = String.create 4 in
          Binary_packing.pack_signed_32_int i
            ~byte_order:`Little_endian ~buf ~pos:0;
          buf
        end
      | `string s ->
        begin match typ with
        | 'H' ->
          let r = ref [] in
          String.iter s (fun c ->
            r := sprintf "%02x" (Char.to_int c) :: !r
          );
          String.concat ~sep:"" (List.rev !r) ^ "\000"
        | _ -> s ^ "\000"
        end
    in
    List.map al.S.optional_content (fun (tag, typ, c) ->
      sprintf "%s%c%s" tag typ (content typ c))
    |! String.concat ~sep:""
  in
  return {
    qname; flag; ref_id; pos; mapq; bin; cigar;
    next_ref_id; pnext; tlen; seq; qual; optional;}

let downgrader () : (Biocaml_sam.item, raw_item, _) Biocaml_transform.t =
  let name = "bam_item_downgrader" in
  let queue = Dequeue.create ~dummy:(`header ("no", [])) () in
  let items_count = ref 0 in
  let ref_dict = ref [| |] in
  let ref_dict_done = ref false in
  let header = Buffer.create 256 in
  let rec next stopped =
    dbg "  queue: %d  items_count: %d"
      (Dequeue.length queue) !items_count;
    begin match Dequeue.is_empty queue, stopped with
    | true, true ->`end_of_stream
    | true, false -> `not_ready
    | false, _ ->
      incr items_count;
      begin match Dequeue.take_front_exn queue with
      | `comment c ->
        Buffer.add_string header "@CO\t";
        Buffer.add_string header c;
        Buffer.add_string header "\n";
        next stopped
      | `header_line (version, ordering, rest) ->
        if Buffer.contents header <> "" then
          `error (`header_line_not_first (Buffer.contents header))
        else begin
          ksprintf (Buffer.add_string header) "@HD\tVN:%s\tSO:%s%s\n"
            version
            (match ordering with
            | `unknown -> "unknown"
            | `unsorted -> "unsorted"
            | `queryname -> "queryname"
            | `coordinate -> "coordinate")
            (List.map rest (fun (t, v) -> sprintf "\t%s:%s" t v)
             |! String.concat ~sep:"");
          next stopped
        end
      | `header (pretag, l) ->
        ksprintf (Buffer.add_string header) "@%s" pretag;
        List.iter l (fun (t, v) ->
          ksprintf (Buffer.add_string header) "\t%s:%s" t v;
        );
        Buffer.add_string header "\n";
        next stopped
      | `reference_sequence_dictionary r ->
        ref_dict := r;
        `output (`header (Buffer.contents header))
      | `alignment al ->
        if not !ref_dict_done 
        then begin
          dbg "reference_information: %d" Array.(length !ref_dict);
          ref_dict_done := true;
          Dequeue.push_front queue (`alignment al);
          `output (`reference_information (Array.map !ref_dict ~f:(fun rs ->
            let open Biocaml_sam in
            (rs.ref_name, rs.ref_length))))
        end
        else begin
          match downgrade_alignement al !ref_dict with
          | Ok o -> `output (`alignment o)
          | Error e -> `error e
        end
      end
    end
  in
  Biocaml_transform.make_stoppable ~name ~feed:(Dequeue.push_back queue) ()
    ~next
