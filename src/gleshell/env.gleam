//// Shell environment: cwd, variables, last exit status.

import gleam/dict.{type Dict}
import gleshell/sys
import gleshell/value.{type Value, Nothing, String}

pub type Env {
  Env(cwd: String, vars: Dict(String, Value), last_exit: Int)
}

pub fn new() -> Env {
  let cwd = case sys.get_cwd() {
    Ok(c) -> c
    Error(_) -> "."
  }
  Env(cwd: cwd, vars: dict.new(), last_exit: 0)
}

pub fn get_var(env: Env, name: String) -> Value {
  case name {
    "PWD" | "pwd" -> String(env.cwd)
    "in" ->
      case dict.get(env.vars, "in") {
        Ok(v) -> v
        Error(Nil) -> Nothing
      }
    _ ->
      case dict.get(env.vars, name) {
        Ok(v) -> v
        Error(Nil) ->
          case sys.getenv(name) {
            Ok(s) -> String(s)
            Error(Nil) -> Nothing
          }
      }
  }
}

pub fn set_var(env: Env, name: String, value: Value) -> Env {
  Env(..env, vars: dict.insert(env.vars, name, value))
}

pub fn set_input(env: Env, input: Value) -> Env {
  set_var(env, "in", input)
}

pub fn set_cwd(env: Env, path: String) -> Result(Env, String) {
  case sys.set_cwd(path) {
    Ok(Nil) -> {
      let cwd = case sys.get_cwd() {
        Ok(c) -> c
        Error(_) -> path
      }
      Ok(Env(..env, cwd: cwd))
    }
    Error(e) -> Error(e)
  }
}

pub fn set_exit(env: Env, code: Int) -> Env {
  Env(..env, last_exit: code)
}
