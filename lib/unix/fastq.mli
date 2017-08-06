(** FASTQ files. The
    {{:http://en.wikipedia.org/wiki/FASTQ_format}FASTQ file format} is
    repeated sequence of 4 lines:

    {v
    \@name
    sequence
    +comment
    qualities
    ...
    v}

    The name line begins with an \@ character, which is omitted in the
    parsed {!item} type provided by this module. Any spaces after the
    \@ are retained, but the specification implies that there shouldn't
    be any such spaces. Trailing whitespace is also retained since you
    should not normally have such files.

    The comment line, which begins with a +, is handled similarly. The
    purpose of the comment line is unclear and it is rarely
    used. Also, "comment" may not be the correct term for this line.

    The name line may be structured into two parts: a sequence
    identifier and an optional description. We provide a function
    {!split_name} to parse such a value. However, an [item]'s [name]
    field contains the unparsed string because it is unclear whether
    fastq files really follow this. Also the format of the description
    is unspecified. When it is provided, usually it has some
    additional structure, so the minimal amount of parsing done by
    {!split_name} isn't too useful anyway.

    Illumina uses a systematic format for the name line that serves as
    a unique sequence identifier. Use
    {!Illumina.sequence_id_of_string} to parse an [item]'s [name]
    field when you have fastq files produced by Casava version >=
    1.8. Earlier versions of Casava returned a different format, which
    is not currently supported in this module (it could be easily
    added).

    The qualities line is returned as a plain string, but it is
    required to be decodable as either Phred or Solexa scores. Modules
    [Phred_score] and [Solexa_score] can be used to parse as needed.

    Older FASTQ files allowed the sequence and qualities strings to
    span multiple lines. This is discouraged and is not supported by
    this module.
*)
open Core_kernel

type item = {
  name: string;
  sequence: string;
  comment: string;
  qualities: string;
} [@@deriving sexp]

(** Split a name string into a sequence identifier and an optional
    description. It is assumed that the given string is from an
    [item]'s [name] field, i.e. that it doesn't contain a leading \@
    char. *)
val split_name : string -> string * string option


(******************************************************************************)
(** {2 Input/Output } *)
(******************************************************************************)
module MakeIO (Future : Future.S) : sig
  open Future

  val read : Reader.t -> item Or_error.t Pipe.Reader.t

  val write : Writer.t -> item Pipe.Reader.t -> unit Deferred.t

  val write_file
    : ?perm:int
    -> ?append:bool
    -> string
    -> item Pipe.Reader.t
    -> unit Deferred.t

end
include module type of MakeIO(Future_unix)


(******************************************************************************)
(** {2 Illumina-specific operations} *)
(******************************************************************************)
module Illumina : sig
  type surface = [`Top | `Bottom]

  type tile = private {
    surface : surface;
    swath : int; (** 1, 2, or 3 *)
    number : int; (** 1 - 99, but usually 1 - 8 *)
  }

  (** E.g. [tile_of_string "2304"] parses to
      - surface = Bottom
      - swath = 3
      - tile_num = 4
  *)
  val tile_of_string : string -> tile Or_error.t

  (** Inverse of [tile_of_string]. *)
  val tile_to_string : tile -> string

  (** Content of name lines as generated by Casava versions >= 1.8. *)
  type sequence_id = private {
    instrument : string;
    run_number : int;
    flowcell_id : string;
    lane : int;
    tile : tile;
    x_pos : int;
    y_pos : int;
    read : int;
    is_filtered : bool;
    control_number : int;
    index : string
  }

  (** Parse a name string to a structured Illumina sequence_id. It is
      assumed that the given string is from an [item]'s [name] field,
      i.e. that it doesn't contain a leading \@ char. *)
  val sequence_id_of_string : string -> sequence_id Or_error.t

end


(******************************************************************************)
(** {2 Low-level Printing} *)
(******************************************************************************)

(** This function converts [item] values to strings that can be dumped
    to a file, i.e. they contain full-lines, including {i all}
    end-of-line characters. *)
val item_to_string: item -> string


(******************************************************************************)
(** {2 Low-level Parsing} *)
(******************************************************************************)
val name_of_line : ?pos:Pos.t -> Line.t -> string Or_error.t
val sequence_of_line : ?pos:Pos.t -> Line.t -> string
val comment_of_line : ?pos:Pos.t -> Line.t -> string Or_error.t

(** [qualities sequence line] parses given qualities [line] in the
    context of a previously parsed [sequence]. The [sequence] is
    needed to assure the correct number of quality scores are
    provided. If not provided, this check is omitted. *)
val qualities_of_line :
  ?pos:Pos.t ->
  ?sequence:string ->
  Line.t ->
  string Or_error.t
