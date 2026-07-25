//// gleshell — a structured-data shell in Gleam, inspired by Nushell.

import argv
import filepath
import gleam/io
import gleam/string
import gleshell/color
import gleshell/display
import gleshell/env
import gleshell/eval
import gleshell/sys
import gleshell/value.{Nothing}
import simplifile

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
  sys.println(string.join(
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
  sys.println(
    "gleshell 0.1 — structured data shell (type `help`, `exit` to quit; Tab completes commands/paths, Ctrl+R search)",
  )
  repl_loop(env)
}

fn repl_loop(env: env.Env) -> Nil {
  let prompt = prompt_for(env)
  case sys.get_line(prompt) {
    Error("eof") -> {
      sys.println("")
      Nil
    }
    // Ctrl+C cancelled the line (edlin path); stay in the REPL.
    Error("interrupted") -> {
      sys.println("")
      repl_loop(env)
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

/// Zero-config prompt inspired by Starship:
/// blank line, directory (+ optional git branch), then a green/red `❯`.
///
/// Status lines are printed once; only the character is the line-editor prompt
/// (the raw editor redraws a single line).
fn prompt_for(env: env.Env) -> String {
  let on = color.enabled()
  let path = color.prompt_path(on, display_cwd(env.cwd))
  let git = case git_branch(env.cwd) {
    Ok(branch) ->
      color.separator(on, " on ")
      <> color.prompt_git(on, " " <> branch)
    Error(Nil) -> ""
  }
  sys.println("")
  sys.println(path <> git)
  prompt_character(env.last_exit)
}

fn prompt_character(last_exit: Int) -> String {
  let on = color.enabled()
  let mark = case last_exit {
    0 -> color.prompt_character_ok(on, "❯")
    _ -> color.prompt_character_err(on, "❯")
  }
  mark <> " "
}

/// Full cwd for the prompt, with `$HOME` shown as `~`.
fn display_cwd(cwd: String) -> String {
  case sys.home_dir() {
    Ok(home) -> abbreviate_home(cwd, home)
    Error(_) -> cwd
  }
}

fn abbreviate_home(path: String, home: String) -> String {
  case path == home {
    True -> "~"
    False ->
      case string.starts_with(path, home <> "/") {
        // Keep the leading `/` after home so `~/code` not `~code`.
        True -> "~" <> string.drop_start(path, string.length(home))
        False -> path
      }
  }
}

/// Best-effort branch name by reading `.git` (no `git` process).
fn git_branch(cwd: String) -> Result(String, Nil) {
  case find_git_dir(cwd, 32) {
    Error(Nil) -> Error(Nil)
    Ok(git_dir) -> read_git_head_branch(git_dir)
  }
}

fn find_git_dir(dir: String, budget: Int) -> Result(String, Nil) {
  case budget <= 0 {
    True -> Error(Nil)
    False -> {
      let candidate = filepath.join(dir, ".git")
      case simplifile.is_directory(candidate) {
        Ok(True) -> Ok(candidate)
        _ ->
          case simplifile.is_file(candidate) {
            Ok(True) -> read_gitdir_pointer(candidate)
            _ -> {
              let parent = filepath.directory_name(dir)
              case parent == "" || parent == dir {
                True -> Error(Nil)
                False -> find_git_dir(parent, budget - 1)
              }
            }
          }
      }
    }
  }
}

/// Worktree / linked checkout: `.git` is a file `gitdir: <path>`.
fn read_gitdir_pointer(git_file: String) -> Result(String, Nil) {
  case simplifile.read(git_file) {
    Error(_) -> Error(Nil)
    Ok(body) -> {
      let line = string.trim(first_line(body))
      case string.starts_with(line, "gitdir:") {
        False -> Error(Nil)
        True -> {
          let raw = string.trim(string.drop_start(line, 7))
          case raw {
            "" -> Error(Nil)
            path ->
              case filepath.is_absolute(path) {
                True -> Ok(path)
                False ->
                  Ok(filepath.join(filepath.directory_name(git_file), path))
              }
          }
        }
      }
    }
  }
}

fn read_git_head_branch(git_dir: String) -> Result(String, Nil) {
  case simplifile.read(filepath.join(git_dir, "HEAD")) {
    Error(_) -> Error(Nil)
    Ok(body) -> {
      let line = string.trim(first_line(body))
      case string.starts_with(line, "ref: ") {
        True -> {
          let ref = string.trim(string.drop_start(line, 5))
          // Prefer short branch name: refs/heads/main → main
          case string.starts_with(ref, "refs/heads/") {
            True -> Ok(string.drop_start(ref, 11))
            False -> Ok(filepath.base_name(ref))
          }
        }
        // Detached HEAD — show a short SHA when it looks like one.
        False ->
          case string.length(line) >= 7 {
            True -> Ok(string.slice(line, 0, 7))
            False ->
              case line {
                "" -> Error(Nil)
                other -> Ok(other)
              }
          }
      }
    }
  }
}

fn first_line(s: String) -> String {
  case string.split_once(s, "\n") {
    Ok(#(line, _)) -> line
    Error(Nil) -> s
  }
}

fn print_value(value: value.Value) -> Nil {
  case value {
    Nothing -> Nil
    _ ->
      // External commands that used PTY relay already streamed output to the
      // terminal (needed for run0/sudo password prompts). Skip re-printing
      // when that flag is still set (final pipeline stage was that external).
      case sys.take_output_shown() {
        True -> Nil
        False -> {
          let text = display.render(value)
          case text {
            "" -> Nil
            t -> sys.println(t)
          }
        }
      }
  }
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil
