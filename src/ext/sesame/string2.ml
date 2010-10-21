include ExtString.String

let count f s =
  let f ans c = if f c then ans + 1 else ans in
    fold_left f 0 s
      
let to_index s n = sub s 0 (n+1)
let from_index s n = sub s n (length s - n)
  
let exists' f s =
  fold_left (fun ans c -> f c || ans) false s
    
let for_all f s =
  fold_left (fun ans c -> f c && ans) true s
    
let stripl ?(chars=" \t\r\n") s =
  let p = ref 0 in
  let l = length s in
    while !p < l && contains chars (unsafe_get s !p) do
      incr p;
    done;
    let p = !p in
    let l = ref (l - 1) in
      sub s p (!l - p + 1)
        
let stripr ?(chars=" \t\r\n") s =
  let p = ref 0 in
  let l = length s in
  let p = !p in
  let l = ref (l - 1) in
    while !l >= p && contains chars (unsafe_get s !l) do
      decr l;
    done;
    sub s p (!l - p + 1)
      
let strip_final_cr s =
  let l = String.length s in
    if l > 0 && s.[l-1] = '\r'
    then String.sub s 0 (l-1)
    else s

let rev s =
  let n = String.length s in
  let ans = String.create n in
  let j = ref (n-1) in
  for i = 0 to n - 1 do
    ans.[i] <- s.[!j];
    decr j
  done;
  ans

let fold_lefti f acc str = 
  let r = ref acc in
  for i = 0 to (String.length str - 1) do
    r := f !r i str.[i]
  done;
  !r
