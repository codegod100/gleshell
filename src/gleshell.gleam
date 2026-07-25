//// gleshell — a structured-data shell in Gleam, inspired by Nushell.

import argv
import gleam/io
import gleam/string
import gleshell/color
import gleshell/display
import gleshell/env
import gleshell/eval
import gleshell/sys
import gleshell/value.{Nothing}

pub fn main() -> Nil {
  case argv.load().arguments {
    ["-h"] | ["--help"] | ["help"] -> {
      print_usage()
      Nil
    }
    ["-c", code] -> run_once(code)
    ["-c"] -> {
      io.println_error("gleshell: -c requires a command string")
      halt(2)
    }
    [] -> sys.run_as_shell(fn() { repl(env.new()) })
    args -> run_once(string.join(args, " "))
  }
}

fn print_usage() -> Nil {
  io.println(string.join(
    [
      "gleshell — Gleam shell inspired by Nushell",
      "",
      "Usage:",
      "  gleshell              Interactive REPL",
      "  gleshell -c <code>    Evaluate a one-liner",
      "  gleshell <code>…      Evaluate remaining args as code",
      "",
      "Examples:",
      "  gleshell -c 'ls | where type == file | first 5'",
      "  gleshell -c 'range 10 | reverse | first 3'",
      "  gleshell -c 'echo {name: \"gleshell\", cool: true}'",
      "",
      "In the REPL, type `help` for built-in commands.",
    ],
    "\n",
  ))
}

fn run_once(code: String) -> Nil {
  let env = env.new()
  case eval.eval_source(env, code) {
    eval.Quit(code) -> halt(code)
    eval.Continue(_env, value) -> {
      print_value(value)
      case value {
        value.Fail(_) -> halt(1)
        _ -> Nil
      }
    }
  }
}

fn repl(env: env.Env) -> Nil {
  io.println(
    "gleshell 0.1 — structured data shell (type `help`, `exit` to quit; Ctrl+R reverse search)",
  )
  repl_loop(env)
}

fn repl_loop(env: env.Env) -> Nil {
  let prompt = prompt_for(env)
  case sys.get_line(prompt) {
    Error("eof") -> {
      io.println("")
      Nil
    }
    Error(e) -> {
      io.println_error("read error: " <> e)
      Nil
    }
    Ok(line) -> {
      let line = string.trim(line)
      case line {
        "" -> repl_loop(env)
        _ ->
          case eval.eval_source(env, line) {
            eval.Quit(code) -> {
              case code {
                0 -> Nil
                _ -> halt(code)
              }
            }
            eval.Continue(env2, value) -> {
              print_value(value)
              repl_loop(env2)
            }
          }
      }
    }
  }
}

fn prompt_for(env: env.Env) -> String {
  let base = basename(env.cwd)
  let on = color.enabled()
  color.prompt_name(on, "gleshell")
  <> color.separator(on, ":")
  <> color.prompt_path(on, base)
  <> color.prompt_mark(on, "> ")
}

fn basename(path: String) -> String {
  case string.split(path, "/") {
    [] -> path
    parts ->
      case list_last(parts) {
        "" ->
          // path ended with /
          case parts {
            [only] -> only
            _ -> {
              // take second last non-empty if possible
              path
            }
          }
        name -> name
      }
  }
}

fn list_last(items: List(String)) -> String {
  case items {
    [] -> ""
    [x] -> x
    [_, ..rest] -> list_last(rest)
  }
}

fn print_value(value: value.Value) -> Nil {
  case value {
    Nothing -> Nil
    _ -> {
      let text = display.render(value)
      case text {
        "" -> Nil
        t -> io.println(t)
      }
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil
