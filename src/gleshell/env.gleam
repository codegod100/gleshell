//// Shell environment: cwd, variables, last exit status.
////
//// Nushell-style process env lives under `$env` / `$env.VAR`.

import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import gleshell/sys
import gleshell/value.{type Value, Nothing, Record, String}

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
    // `$env` — full process environment as a record
    "env" -> env_record(env)
    _ ->
      case string.starts_with(name, "env.") {
        // `$env.VAR` — one OS environment variable
        True -> get_os_env(env, string.drop_start(name, 4))
        False ->
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
}

/// Process environment as a record (Nushell `$env`).
/// `PWD` always reflects the shell cwd.
pub fn env_record(env: Env) -> Value {
  let pairs =
    sys.list_env()
    |> list.map(fn(pair) {
      let #(k, v) = pair
      case k {
        "PWD" -> #("PWD", String(env.cwd))
        _ -> #(k, String(v))
      }
    })
  let has_pwd =
    list.any(pairs, fn(pair) {
      let #(k, _) = pair
      k == "PWD"
    })
  let pairs = case has_pwd {
    True -> pairs
    False -> list.append(pairs, [#("PWD", String(env.cwd))])
  }
  Record(pairs)
}

fn get_os_env(env: Env, key: String) -> Value {
  case key {
    "" -> Nothing
    "PWD" | "pwd" -> String(env.cwd)
    _ ->
      case sys.getenv(key) {
        Ok(s) -> String(s)
        Error(Nil) -> Nothing
      }
  }
}

pub fn set_var(env: Env, name: String, value: Value) -> Env {
  Env(..env, vars: dict.insert(env.vars, name, value))
}

/// Set a process environment variable (`$env.NAME = …`).
/// Setting `PWD` changes the shell working directory.
pub fn set_os_env(env: Env, name: String, value: Value) -> Result(Env, String) {
  case name {
    "" -> Error("empty environment variable name")
    "PWD" | "pwd" -> set_cwd(env, value.as_string(value))
    _ -> {
      let _ = sys.setenv(name, value.as_string(value))
      Ok(env)
    }
  }
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
      // Keep process PWD in sync (Nushell does this for `$env.PWD`)
      let _ = sys.setenv("PWD", cwd)
      Ok(Env(..env, cwd: cwd))
    }
    Error(e) -> Error(e)
  }
}

pub fn set_exit(env: Env, code: Int) -> Env {
  Env(..env, last_exit: code)
}
