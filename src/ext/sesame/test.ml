open Printf

let time ?(cout=stderr) f a =
  let init = Sys.time() in
  let b = f a in
  let delt = Sys.time() -. init in
  fprintf cout "finished in %.2f seconds\n%!" delt;
  b
    
let sf ?(cout=stderr) msg f a =
  fprintf cout "%s... %!" msg;
  let b = f a in
  fprintf cout "finished\n%!";
  b
    
let timesf ?(cout=stderr) msg f a =
  let init = Sys.time() in
  fprintf cout "%s... %!" msg;
  let b = f a in
  let delt = Sys.time() -. init in
  fprintf cout "finished in %.2f seconds\n%!" delt;
  b
    
let get_time f a =
  let init = Sys.time() in
  let b = f a in
  let delt = Sys.time() -. init in
  (b, delt)
    
let repeat n f =
  if n < 1 then failwith "cannot execute a function less than 1 time"
  else
    fun a ->
      for i = 1 to n-1 do ignore (f a) done;
      f a
        
