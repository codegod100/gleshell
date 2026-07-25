//// OS / process FFI wrappers.

@external(erlang, "gleshell_ffi", "get_line")
pub fn get_line(prompt: String) -> Result(String, String)

@external(erlang, "gleshell_ffi", "set_cwd")
pub fn set_cwd(path: String) -> Result(Nil, String)

@external(erlang, "gleshell_ffi", "get_cwd")
pub fn get_cwd() -> Result(String, String)

@external(erlang, "gleshell_ffi", "getenv")
pub fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "gleshell_ffi", "setenv")
pub fn setenv(name: String, value: String) -> Result(Nil, Nil)

@external(erlang, "gleshell_ffi", "run_cmd")
pub fn run_cmd(
  command: String,
  args: List(String),
) -> Result(#(Int, String), String)

@external(erlang, "gleshell_ffi", "which")
pub fn which(command: String) -> Result(String, Nil)

@external(erlang, "gleshell_ffi", "home_dir")
pub fn home_dir() -> Result(String, String)
