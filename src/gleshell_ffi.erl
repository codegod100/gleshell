%% Erlang FFI for gleshell: REPL I/O, cwd, env, external processes.
-module(gleshell_ffi).
-export([
    get_line/1,
    parse_line/2,
    run_as_shell/1,
    spawn_shell/2,
    set_cwd/1,
    get_cwd/0,
    getenv/1,
    setenv/2,
    list_env/0,
    run_cmd/2,
    which/1,
    home_dir/0,
    stdout_isatty/0,
    println/1,
    take_output_shown/0,
    clear_output_shown/0
]).

-define(ESC, 16#1b).
-define(CSI_CLEAR_EOL, "\e[K").
-define(HISTORY_MAX, 2000).

%% ---------------------------------------------------------------------------
%% Public: write a line (CRLF in raw TTY mode so multi-line output does not
%% staircase — raw mode does not map LF → CR+LF the way cooked mode does).
%% ---------------------------------------------------------------------------

-spec println(binary()) -> nil.
println(Text) when is_binary(Text) ->
    case get(gleshell_raw) of
        true ->
            io:put_chars([to_crlf(Text), <<"\r\n">>]),
            nil;
        _ ->
            io:put_chars([Text, $\n]),
            nil
    end.

%% Normalize newlines to CRLF without turning existing \r\n into \r\r\n.
to_crlf(Bin) when is_binary(Bin) ->
    B1 = binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]),
    B2 = binary:replace(B1, <<"\r">>, <<"\n">>, [global]),
    binary:replace(B2, <<"\n">>, <<"\r\n">>, [global]).

%% ---------------------------------------------------------------------------
%% Public: read a line (syntax-highlighted when raw TTY mode is active)
%% ---------------------------------------------------------------------------

-spec get_line(binary()) -> {ok, binary()} | {error, binary()}.
get_line(Prompt) when is_binary(Prompt) ->
    case get(gleshell_raw) of
        true ->
            raw_get_line(Prompt);
        _ ->
            classic_get_line(Prompt)
    end.

%% Edlin / get_until path (non-TTY or when raw mode unavailable).
classic_get_line(Prompt) ->
    PromptChars = unicode:characters_to_list(Prompt),
    case io:request(
        standard_io,
        {get_until, unicode, PromptChars, ?MODULE, parse_line, []}
    ) of
        eof ->
            {error, <<"eof">>};
        {error, interrupted} ->
            %% Ctrl+C while reading: cancel line, keep the REPL alive.
            {error, <<"interrupted">>};
        {error, _} ->
            {error, <<"io_error">>};
        Line when is_list(Line); is_binary(Line) ->
            Bin = unicode:characters_to_binary(Line),
            Stripped = string:trim(Bin, trailing, [$\n, $\r]),
            {ok, Stripped};
        Other ->
            try
                Bin = unicode:characters_to_binary(Other),
                Stripped = string:trim(Bin, trailing, [$\n, $\r]),
                {ok, Stripped}
            catch
                _:_ ->
                    {error, <<"io_error">>}
            end
    end.

%% get_until callback: edlin already gathers a full line.
-spec parse_line(term(), term()) ->
    {done, eof | string(), list()} | {more, term()}.
parse_line(_Cont, eof) ->
    {done, eof, []};
parse_line(_Cont, Chars) when is_list(Chars) ->
    {done, Chars, []}.

%% ---------------------------------------------------------------------------
%% Shell bootstrap: prefer OTP raw mode for live syntax highlighting.
%% Falls back to edlin interactive shell when raw is unavailable.
%%
%% Ctrl+C: the BEAM default opens the BREAK menu (a = abort → process exit).
%% Re-exec once with +Bc so Ctrl+C is delivered as a character to our editor
%% (cancel line) instead of killing the shell. See erl(1) +B.
%% ---------------------------------------------------------------------------

-spec run_as_shell(fun(() -> term())) -> nil.
run_as_shell(Fun) when is_function(Fun, 0) ->
    case ensure_plus_bc() of
        {parent, Port} ->
            %% Child owns the TTY; we only wait for its exit status.
            receive
                {Port, {exit_status, Status}} ->
                    erlang:halt(Status)
            end;
        child ->
            enable_shell_history(),
            case try_start_raw() of
                true ->
                    put(gleshell_raw, true),
                    load_line_history(),
                    configure_line_editor(),
                    try
                        Fun()
                    after
                        save_line_history()
                    end,
                    nil;
                false ->
                    erase(gleshell_raw),
                    Parent = self(),
                    case try_start_interactive(Parent, Fun) of
                        {ok, started} ->
                            receive
                                {gleshell_shell_done, ok} ->
                                    nil;
                                {gleshell_shell_done, {error, Class, Reason, Stack}} ->
                                    erlang:raise(Class, Reason, Stack)
                            end;
                        {ok, direct} ->
                            configure_line_editor(),
                            Fun(),
                            nil
                    end
            end
    end.

%% Ensure the emulator was started with +Bc (Ctrl+C → char, not BREAK/abort).
%% Returns `child` when this process should run the REPL, or `{parent, Port}`
%% when we re-exec'd and should wait on the child.
-spec ensure_plus_bc() -> child | {parent, port()}.
ensure_plus_bc() ->
    case os:getenv("GLESHELL_PLUS_BC") of
        "1" ->
            child;
        _ ->
            case already_has_plus_bc() of
                true ->
                    os:putenv("GLESHELL_PLUS_BC", "1"),
                    child;
                false ->
                    reexec_with_plus_bc()
            end
    end.

already_has_plus_bc() ->
    lists:any(
        fun(Var) ->
            case os:getenv(Var) of
                false ->
                    false;
                Flags ->
                    string:find(Flags, "+Bc") =/= nomatch
            end
        end,
        ["ERL_AFLAGS", "ERL_FLAGS", "ERL_ZFLAGS"]
    ).

reexec_with_plus_bc() ->
    os:putenv("GLESHELL_PLUS_BC", "1"),
    case os:getenv("ERL_AFLAGS") of
        false ->
            os:putenv("ERL_AFLAGS", "+Bc");
        Flags ->
            case string:find(Flags, "+Bc") of
                nomatch ->
                    os:putenv("ERL_AFLAGS", "+Bc " ++ Flags);
                _ ->
                    ok
            end
    end,
    case os:find_executable("erl") of
        false ->
            %% No erl on PATH — continue without +Bc (BREAK menu may appear).
            child;
        Erl ->
            Pa = lists:flatmap(fun(D) -> ["-pa", D] end, code:get_path()),
            Extra = init:get_plain_arguments(),
            Args =
                ["+Bc", "-noshell"] ++
                Pa ++
                ["-eval", "gleshell@@main:run(gleshell)", "-extra" | Extra],
            try
                Port = open_port(
                    {spawn_executable, Erl},
                    [exit_status, nouse_stdio, {args, Args}]
                ),
                {parent, Port}
            catch
                _:_ ->
                    child
            end
    end.

try_start_raw() ->
    case stdout_isatty() of
        false ->
            false;
        true ->
            case catch shell:start_interactive({noshell, raw}) of
                ok ->
                    true;
                {error, already_started} ->
                    %% Cannot switch an existing interactive shell into raw.
                    false;
                _ ->
                    false
            end
    end.

try_start_interactive(Parent, Fun) ->
    _ = application:set_env(stdlib, shell_slogan, "", [{persistent, true}]),
    case shell:start_interactive({gleshell_ffi, spawn_shell, [Parent, Fun]}) of
        ok ->
            {ok, started};
        {error, already_started} ->
            {ok, direct};
        {error, _} ->
            {ok, direct}
    end.

-spec spawn_shell(pid(), fun(() -> term())) -> pid().
spawn_shell(Parent, Fun) when is_pid(Parent), is_function(Fun, 0) ->
    spawn(fun() ->
        try
            configure_line_editor(),
            Fun()
        of
            _ ->
                Parent ! {gleshell_shell_done, ok},
                exit(die)
        catch
            Class:Reason:Stack ->
                Parent ! {gleshell_shell_done, {error, Class, Reason, Stack}},
                erlang:raise(Class, Reason, Stack)
        end
    end).

configure_line_editor() ->
    _ = io:setopts([{encoding, unicode}, binary]),
    try
        io:setopts([{line_history, true}])
    catch
        _:_ ->
            ok
    end,
    ok.

enable_shell_history() ->
    case application:get_env(kernel, shell_history_path) of
        {ok, _} ->
            ok;
        undefined ->
            Path = filename:basedir(user_cache, "gleshell-history"),
            _ = application:set_env(
                kernel, shell_history_path, Path, [{persistent, true}]
            ),
            ok
    end,
    case application:get_env(kernel, shell_history) of
        {ok, _} ->
            ok;
        undefined ->
            _ = application:set_env(
                kernel, shell_history, enabled, [{persistent, true}]
            ),
            ok
    end.

%% ---------------------------------------------------------------------------
%% Raw-mode line editor with Nushell-style syntax highlighting
%% ---------------------------------------------------------------------------
%%
%% Buffer model: Left is graphemes before the cursor (reversed),
%% Right is graphemes after the cursor (normal order).
%% History is a list of binaries (newest first).

raw_get_line(Prompt) when is_binary(Prompt) ->
    PromptList = unicode:characters_to_list(Prompt),
    History = case get(gleshell_history) of
        L when is_list(L) -> L;
        _ -> []
    end,
    redraw(PromptList, [], []),
    raw_loop(PromptList, [], [], History, 0, <<>>).

%% HistPos: 0 = editing current buffer; N>0 = viewing Nth history entry.
%% Saved: buffer saved when first entering history navigation.
raw_loop(Prompt, Left, Right, History, HistPos, Saved) ->
    case read_key() of
        eof ->
            io:put_chars("\r\n"),
            {error, <<"eof">>};
        {error, _} ->
            io:put_chars("\r\n"),
            {error, <<"io_error">>};
        enter ->
            Line = buffer_to_bin(Left, Right),
            io:put_chars("\r\n"),
            push_history(Line),
            {ok, Line};
        {char, C} when is_integer(C), C >= 32, C =/= 127 ->
            %% Printable Unicode codepoint
            NewLeft = [C | Left],
            redraw(Prompt, NewLeft, Right),
            raw_loop(Prompt, NewLeft, Right, History, 0, <<>>);
        backspace ->
            case Left of
                [] ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                [_ | Rest] ->
                    redraw(Prompt, Rest, Right),
                    raw_loop(Prompt, Rest, Right, History, 0, <<>>)
            end;
        delete ->
            case Right of
                [] ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                [_ | Rest] ->
                    redraw(Prompt, Left, Rest),
                    raw_loop(Prompt, Left, Rest, History, 0, <<>>)
            end;
        left ->
            case Left of
                [] ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                [C | Rest] ->
                    redraw(Prompt, Rest, [C | Right]),
                    raw_loop(Prompt, Rest, [C | Right], History, HistPos, Saved)
            end;
        right ->
            case Right of
                [] ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                [C | Rest] ->
                    redraw(Prompt, [C | Left], Rest),
                    raw_loop(Prompt, [C | Left], Rest, History, HistPos, Saved)
            end;
        home ->
            NewRight = lists:reverse(Left) ++ Right,
            redraw(Prompt, [], NewRight),
            raw_loop(Prompt, [], NewRight, History, HistPos, Saved);
        'end' ->
            NewLeft = lists:reverse(Right) ++ Left,
            redraw(Prompt, NewLeft, []),
            raw_loop(Prompt, NewLeft, [], History, HistPos, Saved);
        up ->
            hist_nav(Prompt, Left, Right, History, HistPos, Saved, 1);
        down ->
            hist_nav(Prompt, Left, Right, History, HistPos, Saved, -1);
        ctrl_a ->
            NewRight = lists:reverse(Left) ++ Right,
            redraw(Prompt, [], NewRight),
            raw_loop(Prompt, [], NewRight, History, HistPos, Saved);
        ctrl_e ->
            NewLeft = lists:reverse(Right) ++ Left,
            redraw(Prompt, NewLeft, []),
            raw_loop(Prompt, NewLeft, [], History, HistPos, Saved);
        ctrl_u ->
            redraw(Prompt, [], Right),
            raw_loop(Prompt, [], Right, History, 0, <<>>);
        ctrl_k ->
            redraw(Prompt, Left, []),
            raw_loop(Prompt, Left, [], History, 0, <<>>);
        ctrl_w ->
            {NewLeft, _} = kill_word(Left),
            redraw(Prompt, NewLeft, Right),
            raw_loop(Prompt, NewLeft, Right, History, 0, <<>>);
        ctrl_d ->
            case {Left, Right} of
                {[], []} ->
                    io:put_chars("\r\n"),
                    {error, <<"eof">>};
                {_, []} ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                {_, [_ | Rest]} ->
                    redraw(Prompt, Left, Rest),
                    raw_loop(Prompt, Left, Rest, History, 0, <<>>)
            end;
        ctrl_c ->
            %% Cancel current line (like bash) and return empty.
            io:put_chars("^C\r\n"),
            {ok, <<>>};
        ctrl_l ->
            io:put_chars("\e[H\e[2J"),
            redraw(Prompt, Left, Right),
            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
        ctrl_r ->
            reverse_search(Prompt, History);
        tab ->
            tab_complete(Prompt, Left, Right, History, HistPos, Saved);
        _Other ->
            raw_loop(Prompt, Left, Right, History, HistPos, Saved)
    end.

%% ---------------------------------------------------------------------------
%% Tab: filename completion (path under cursor)
%% ---------------------------------------------------------------------------
%%
%% Completes the token before the cursor as a filesystem path.
%% One match → insert it (directories get a trailing /).
%% Several matches → extend the longest common prefix; if that does not
%% advance the buffer, list candidates under the line and redraw.

tab_complete(Prompt, Left, Right, History, HistPos, Saved) ->
    {PrefixRev, Word} = word_before_cursor(Left),
    case filename_completions(Word) of
        [] ->
            beep(),
            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
        [Only] ->
            NewLeft = apply_completed_word(PrefixRev, Only),
            redraw(Prompt, NewLeft, Right),
            raw_loop(Prompt, NewLeft, Right, History, 0, <<>>);
        Matches ->
            Common = longest_common_prefix(Matches),
            case Common =/= Word andalso length(Common) >= length(Word) of
                true ->
                    NewLeft = apply_completed_word(PrefixRev, Common),
                    redraw(Prompt, NewLeft, Right),
                    raw_loop(Prompt, NewLeft, Right, History, 0, <<>>);
                false ->
                    show_completions(Matches),
                    redraw(Prompt, Left, Right),
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved)
            end
    end.

beep() ->
    io:put_chars([7]).

%% Left is graphemes before the cursor in reverse order.
%% Returns {PrefixRev, WordForward} where Word is the path token.
word_before_cursor(Left) ->
    take_completion_word(Left, []).

%% Acc: walking Left (reversed buffer) with [C|Acc] rebuilds the word forward.
take_completion_word([], Acc) ->
    {[], Acc};
take_completion_word([C | Rest], Acc) ->
    case is_completion_break(C) of
        true ->
            {[C | Rest], Acc};
        false ->
            take_completion_word(Rest, [C | Acc])
    end.

is_completion_break(C) when C =:= $\s; C =:= $\t ->
    true;
is_completion_break(C) when C =:= $|; C =:= $;; C =:= $& ->
    true;
is_completion_break(C) when C =:= $(; C =:= $); C =:= $[; C =:= $] ->
    true;
is_completion_break(C) when C =:= ${; C =:= $}; C =:= $<; C =:= $> ->
    true;
is_completion_break(C) when C =:= $'; C =:= $" ->
    true;
is_completion_break(_) ->
    false.

apply_completed_word(PrefixRev, Word) ->
    lists:reverse(Word) ++ PrefixRev.

%% Return sorted completion strings (as typed, with ~ preserved; dirs end in /).
filename_completions(Word) ->
    {ListDirTyped, Base, InsertPrefix} = split_completion_word(Word),
    ListDir = expand_home_path(ListDirTyped),
    case file:list_dir(ListDir) of
        {ok, Names0} ->
            Names = lists:sort(Names0),
            [
                InsertPrefix ++ maybe_dir_slash(ListDir, Name)
             || Name <- Names,
                lists:prefix(Base, Name),
                show_dotfile(Base, Name)
            ];
        {error, _} ->
            []
    end.

%% Hide dotfiles unless the partial name already starts with '.'.
show_dotfile([$. | _], _) ->
    true;
show_dotfile(_, [$. | _]) ->
    false;
show_dotfile(_, _) ->
    true.

maybe_dir_slash(ListDir, Name) ->
    case filelib:is_dir(filename:join(ListDir, Name)) of
        true -> Name ++ "/";
        false -> Name
    end.

%% Split a path word into {dir_to_list, basename_prefix, insert_prefix}.
%% insert_prefix is the directory part as the user typed it (incl. trailing /).
split_completion_word(Word) ->
    case rsplit_path(Word) of
        {none, Base} ->
            {".", Base, ""};
        {Dir, Base} ->
            ListDir =
                case Dir of
                    "" -> "/";
                    _ -> Dir
                end,
            InsertPrefix =
                case Dir of
                    "" -> "/";
                    _ -> Dir ++ "/"
                end,
            {ListDir, Base, InsertPrefix}
    end.

%% Rightmost / splits directory from the partial basename.
rsplit_path(Word) ->
    rsplit_path(lists:reverse(Word), []).

rsplit_path([], Acc) ->
    {none, Acc};
rsplit_path([$/ | Rest], Acc) ->
    {lists:reverse(Rest), Acc};
rsplit_path([C | Rest], Acc) ->
    rsplit_path(Rest, [C | Acc]).

expand_home_path(Path) ->
    case Path of
        "~" ->
            home_path_string();
        [$~, $/ | More] ->
            home_path_string() ++ "/" ++ More;
        _ ->
            Path
    end.

home_path_string() ->
    case os:getenv("HOME") of
        false -> ".";
        Home when is_list(Home) -> Home;
        Home when is_binary(Home) -> unicode:characters_to_list(Home)
    end.

longest_common_prefix([]) ->
    "";
longest_common_prefix([H | T]) ->
    lists:foldl(fun lcp2/2, H, T).

lcp2(A, B) ->
    lcp2(A, B, []).

lcp2([X | As], [X | Bs], Acc) ->
    lcp2(As, Bs, [X | Acc]);
lcp2(_, _, Acc) ->
    lists:reverse(Acc).

show_completions(Matches) ->
    io:put_chars("\r\n"),
    case io:columns() of
        {ok, Cols} when is_integer(Cols), Cols > 8 ->
            print_completion_columns(Matches, Cols);
        _ ->
            io:put_chars(lists:join("  ", Matches)),
            io:put_chars("\r\n")
    end.

print_completion_columns(Matches, Cols) ->
    MaxLen = lists:max([0 | [length(M) || M <- Matches]]),
    Width = MaxLen + 2,
    PerRow = max(1, Cols div Width),
    print_rows(Matches, PerRow, Width).

print_rows([], _PerRow, _Width) ->
    ok;
print_rows(Matches, PerRow, Width) ->
    {Row, Rest} = take_n(Matches, PerRow, []),
    Line = [
        pad_cell(M, Width)
     || M <- Row
    ],
    io:put_chars([Line, "\r\n"]),
    print_rows(Rest, PerRow, Width).

take_n(List, 0, Acc) ->
    {lists:reverse(Acc), List};
take_n([], _N, Acc) ->
    {lists:reverse(Acc), []};
take_n([H | T], N, Acc) ->
    take_n(T, N - 1, [H | Acc]).

pad_cell(S, Width) ->
    Pad = Width - length(S),
    case Pad > 0 of
        true -> S ++ lists:duplicate(Pad, $\s);
        false -> S ++ "  "
    end.

hist_nav(Prompt, Left, Right, History, HistPos, Saved, Delta) ->
    NewPos = HistPos + Delta,
    Len = length(History),
    if
        NewPos < 0 ->
            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
        NewPos =:= 0 ->
            %% Restore saved draft
            {L, R} = bin_to_buffer(Saved),
            redraw(Prompt, L, R),
            raw_loop(Prompt, L, R, History, 0, <<>>);
        NewPos > Len ->
            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
        true ->
            NewSaved = case HistPos of
                0 -> buffer_to_bin(Left, Right);
                _ -> Saved
            end,
            Entry = lists:nth(NewPos, History),
            {L, R} = bin_to_buffer(Entry),
            redraw(Prompt, L, R),
            raw_loop(Prompt, L, R, History, NewPos, NewSaved)
    end.

%% Minimal Ctrl+R reverse-i-search over history.
reverse_search(Prompt, History) ->
    reverse_search_loop(Prompt, History, [], match_history(History, [])).

reverse_search_loop(Prompt, History, Query, Match) ->
    Hint = unicode:characters_to_list(
        ["(reverse-i-search)`", Query, "': ", Match]
    ),
    io:put_chars([$\r, Hint, ?CSI_CLEAR_EOL]),
    case read_key() of
        eof ->
            io:put_chars("\r\n"),
            {error, <<"eof">>};
        enter ->
            Line = iolist_to_binary(Match),
            io:put_chars("\r\n"),
            push_history(Line),
            {ok, Line};
        ctrl_c ->
            io:put_chars("\r\n"),
            redraw(Prompt, [], []),
            raw_loop(Prompt, [], [], History, 0, <<>>);
        ctrl_g ->
            redraw(Prompt, [], []),
            raw_loop(Prompt, [], [], History, 0, <<>>);
        ctrl_r ->
            %% Find older match
            NewMatch = match_history_after(History, Query, Match),
            reverse_search_loop(Prompt, History, Query, NewMatch);
        backspace ->
            NewQuery = case Query of
                [] -> [];
                [_ | _] -> lists:droplast(Query)
            end,
            reverse_search_loop(
                Prompt, History, NewQuery, match_history(History, NewQuery)
            );
        {char, C} when is_integer(C), C >= 32, C =/= 127 ->
            NewQuery = Query ++ [C],
            reverse_search_loop(
                Prompt, History, NewQuery, match_history(History, NewQuery)
            );
        _ ->
            reverse_search_loop(Prompt, History, Query, Match)
    end.

match_history(_History, []) ->
    "";
match_history(History, Query) ->
    QBin = unicode:characters_to_binary(Query),
    case first_match(History, QBin) of
        undefined -> "";
        Bin -> unicode:characters_to_list(Bin)
    end.

match_history_after(History, Query, CurrentMatch) ->
    QBin = unicode:characters_to_binary(Query),
    CurBin = unicode:characters_to_binary(CurrentMatch),
    case skip_until_then_match(History, CurBin, QBin, false) of
        undefined -> CurrentMatch;
        Bin -> unicode:characters_to_list(Bin)
    end.

first_match([], _) ->
    undefined;
first_match([H | T], Q) ->
    case binary:match(H, Q) of
        nomatch -> first_match(T, Q);
        _ -> H
    end.

skip_until_then_match([], _Cur, _Q, _Seen) ->
    undefined;
skip_until_then_match([H | T], Cur, Q, false) ->
    case H =:= Cur of
        true -> skip_until_then_match(T, Cur, Q, true);
        false -> skip_until_then_match(T, Cur, Q, false)
    end;
skip_until_then_match([H | T], Cur, Q, true) ->
    case binary:match(H, Q) of
        nomatch -> skip_until_then_match(T, Cur, Q, true);
        _ -> H
    end.

kill_word([]) ->
    {[], []};
kill_word(Left) ->
    %% Left is reversed: strip trailing spaces then a word.
    L1 = drop_while_space(Left),
    drop_while_word(L1).

drop_while_space([C | Rest]) when C =:= $\s; C =:= $\t ->
    drop_while_space(Rest);
drop_while_space(L) ->
    L.

drop_while_word([]) ->
    {[], []};
drop_while_word([C | Rest]) when C =:= $\s; C =:= $\t ->
    {[C | Rest], []};
drop_while_word([_ | Rest]) ->
    drop_while_word(Rest).

redraw(Prompt, Left, Right) ->
    Full = lists:reverse(Left) ++ Right,
    FullBin = unicode:characters_to_binary(Full),
    Colored = highlight_line(FullBin),
    io:put_chars([$\r, Prompt, Colored, ?CSI_CLEAR_EOL]),
    case length(Right) of
        0 ->
            ok;
        N ->
            io:put_chars(["\e[", integer_to_list(N), $D])
    end.

highlight_line(Bin) when is_binary(Bin) ->
    case get(gleshell_color) of
        false ->
            Bin;
        _ ->
            try
                case 'gleshell@highlight':line(Bin) of
                    Out when is_binary(Out) -> Out;
                    Out when is_list(Out) -> unicode:characters_to_binary(Out);
                    _ -> Bin
                end
            catch
                _:_ ->
                    Bin
            end
    end.

buffer_to_bin(Left, Right) ->
    unicode:characters_to_binary(lists:reverse(Left) ++ Right).

bin_to_buffer(Bin) when is_binary(Bin) ->
    Chars = unicode:characters_to_list(Bin),
    {lists:reverse(Chars), []};
bin_to_buffer(List) when is_list(List) ->
    {lists:reverse(List), []}.

%% ---------------------------------------------------------------------------
%% Key reading (raw mode — keys arrive as soon as pressed)
%% ---------------------------------------------------------------------------

read_key() ->
    case io:get_chars("", 1) of
        eof ->
            eof;
        {error, Reason} ->
            {error, Reason};
        <<C/utf8>> ->
            decode_key(C, <<>>);
        [C] when is_integer(C) ->
            decode_key(C, <<>>);
        Bin when is_binary(Bin), byte_size(Bin) > 0 ->
            case unicode:characters_to_list(Bin) of
                [C | _] -> decode_key(C, <<>>);
                _ -> read_key()
            end;
        List when is_list(List), List =/= [] ->
            decode_key(hd(List), <<>>);
        _ ->
            read_key()
    end.

decode_key($\r, _) -> enter;
decode_key($\n, _) -> enter;
decode_key($\t, _) -> tab;
decode_key(127, _) -> backspace;
decode_key($\b, _) -> backspace;
decode_key(1, _) -> ctrl_a;
decode_key(5, _) -> ctrl_e;
decode_key(4, _) -> ctrl_d;
decode_key(3, _) -> ctrl_c;
decode_key(11, _) -> ctrl_k;
decode_key(21, _) -> ctrl_u;
decode_key(23, _) -> ctrl_w;
decode_key(12, _) -> ctrl_l;
decode_key(18, _) -> ctrl_r;
decode_key(?ESC, _) ->
    read_escape();
decode_key(C, _) when is_integer(C), C >= 32 ->
    {char, C};
decode_key(_, _) ->
    other.

read_escape() ->
    case io:get_chars("", 1) of
        eof ->
            other;
        <<"[">> ->
            read_csi();
        <<$O>> ->
            %% SS3 sequences: OH = home, OF = end, OA/OB/OC/OD arrows
            case io:get_chars("", 1) of
                <<"A">> -> up;
                <<"B">> -> down;
                <<"C">> -> right;
                <<"D">> -> left;
                <<"H">> -> home;
                <<"F">> -> 'end';
                _ -> other
            end;
        _ ->
            other
    end.

read_csi() ->
    read_csi_params([]).

read_csi_params(Acc) ->
    case io:get_chars("", 1) of
        eof ->
            other;
        <<C/utf8>> when C >= $0, C =< $9 ->
            read_csi_params([C | Acc]);
        <<$;>> ->
            read_csi_params([$; | Acc]);
        <<$~>> ->
            Params = lists:reverse(Acc),
            case Params of
                "1" -> home;
                "3" -> delete;
                "4" -> 'end';
                "7" -> home;
                "8" -> 'end';
                _ -> other
            end;
        <<"A">> ->
            up;
        <<"B">> ->
            down;
        <<"C">> ->
            right;
        <<"D">> ->
            left;
        <<"H">> ->
            home;
        <<"F">> ->
            'end';
        _ ->
            other
    end.

%% ---------------------------------------------------------------------------
%% History persistence
%% ---------------------------------------------------------------------------

history_file() ->
    case application:get_env(kernel, shell_history_path) of
        {ok, Path} when is_list(Path) ->
            filename:join(Path, "lines");
        {ok, Path} when is_binary(Path) ->
            filename:join(unicode:characters_to_list(Path), "lines");
        _ ->
            filename:join(
                filename:basedir(user_cache, "gleshell-history"), "lines"
            )
    end.

load_line_history() ->
    File = history_file(),
    case file:read_file(File) of
        {ok, Bin} ->
            Lines = [
                L
             || L <- binary:split(Bin, <<"\n">>, [global]),
                L =/= <<>>
            ],
            %% Newest first
            put(gleshell_history, lists:reverse(Lines));
        _ ->
            put(gleshell_history, [])
    end,
    put(gleshell_color, true),
    ok.

save_line_history() ->
    case get(gleshell_history) of
        Hist when is_list(Hist) ->
            File = history_file(),
            _ = filelib:ensure_dir(File),
            %% Store oldest-first for human readability
            Body = [[L, $\n] || L <- lists:reverse(lists:sublist(Hist, ?HISTORY_MAX))],
            _ = file:write_file(File, Body),
            ok;
        _ ->
            ok
    end.

push_history(<<>>) ->
    ok;
push_history(Line) when is_binary(Line) ->
    Hist = case get(gleshell_history) of
        L when is_list(L) -> L;
        _ -> []
    end,
    New = case Hist of
        [Line | _] -> Hist;
        _ -> [Line | Hist]
    end,
    put(gleshell_history, lists:sublist(New, ?HISTORY_MAX)),
    ok.

%% ---------------------------------------------------------------------------
%% OS / process helpers
%% ---------------------------------------------------------------------------

-spec set_cwd(binary()) -> {ok, nil} | {error, binary()}.
set_cwd(Path) when is_binary(Path) ->
    case file:set_cwd(unicode:characters_to_list(Path)) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, reason_to_bin(Reason)}
    end.

-spec get_cwd() -> {ok, binary()} | {error, binary()}.
get_cwd() ->
    case file:get_cwd() of
        {ok, Dir} ->
            {ok, unicode:characters_to_binary(Dir)};
        {error, Reason} ->
            {error, reason_to_bin(Reason)}
    end.

-spec getenv(binary()) -> {ok, binary()} | {error, nil}.
getenv(Name) when is_binary(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false ->
            {error, nil};
        Value ->
            {ok, unicode:characters_to_binary(Value)}
    end.

-spec setenv(binary(), binary()) -> {ok, nil}.
setenv(Name, Value) when is_binary(Name), is_binary(Value) ->
    os:putenv(unicode:characters_to_list(Name), unicode:characters_to_list(Value)),
    {ok, nil}.

%% All process environment variables as a list of {Name, Value} binaries.
-spec list_env() -> list({binary(), binary()}).
list_env() ->
    lists:map(
        fun(Entry) ->
            case string:split(Entry, "=", leading) of
                [K, V] ->
                    {unicode:characters_to_binary(K), unicode:characters_to_binary(V)};
                [K] ->
                    {unicode:characters_to_binary(K), <<>>};
                _ ->
                    {<<>>, <<>>}
            end
        end,
        os:getenv()
    ).

-spec which(binary()) -> {ok, binary()} | {error, nil}.
which(Command) when is_binary(Command) ->
    case os:find_executable(unicode:characters_to_list(Command)) of
        false ->
            {error, nil};
        Path ->
            {ok, unicode:characters_to_binary(Path)}
    end.

-spec home_dir() -> {ok, binary()} | {error, binary()}.
home_dir() ->
    case os:getenv("HOME") of
        false ->
            {error, <<"HOME not set">>};
        Home ->
            {ok, unicode:characters_to_binary(Home)}
    end.

-spec stdout_isatty() -> boolean().
stdout_isatty() ->
    case io:columns() of
        {ok, _} ->
            true;
        _ ->
            try
                case prim_tty:isatty(stdout) of
                    true -> true;
                    _ -> false
                end
            catch
                _:_ ->
                    false
            end
    end.

%% ---------------------------------------------------------------------------
%% External commands
%%
%% Erlang's erl_child_setup detaches from the controlling TTY, so tools that
%% need interactive auth (run0, sudo, pkexec, polkit/pkttyagent) fail with:
%%   "interactive authentication has not been enabled by the calling program"
%%
%% When a TTY is available and util-linux `script` is on PATH, we allocate a
%% PTY for the child and relay bytes between that session and the real
%% terminal so password prompts work. Output is still captured for pipelines.
%% ---------------------------------------------------------------------------

-spec run_cmd(binary(), [binary()]) -> {ok, {integer(), binary()}} | {error, binary()}.
run_cmd(Command, Args) when is_binary(Command), is_list(Args) ->
    case os:find_executable(unicode:characters_to_list(Command)) of
        false ->
            {error, <<"command not found: ", Command/binary>>};
        Path ->
            PortArgs = [unicode:characters_to_list(A) || A <- Args],
            try
                case {os:find_executable("script"), find_tty_path()} of
                    {Script, {ok, Tty}} when is_list(Script) ->
                        run_cmd_pty(Script, Path, PortArgs, Tty);
                    _ ->
                        run_cmd_direct(Path, PortArgs)
                end
            catch
                _:Reason ->
                    {error, reason_to_bin(Reason)}
            end
    end.

run_cmd_direct(Path, PortArgs) ->
    Port = open_port(
        {spawn_executable, Path},
        [
            binary,
            exit_status,
            stderr_to_stdout,
            use_stdio,
            stream,
            {args, PortArgs}
        ]
    ),
    collect_output(Port, <<>>).

%% Run via `script` so the child gets a controlling TTY (PTY), and relay I/O
%% with the real terminal for interactive authentication and prompts.
run_cmd_pty(Script, Path, PortArgs, TtyPath) ->
    Port = open_port(
        {spawn_executable, Script},
        [
            binary,
            exit_status,
            stderr_to_stdout,
            use_stdio,
            stream,
            %% POSIX shell: caller's $SHELL may be nu/fish and break -c/--.
            {env, [{"SHELL", "/bin/sh"}]},
            {args, ["-q", "-e", "/dev/null", "--", Path | PortArgs]}
        ]
    ),
    case file:open(TtyPath, [write, raw, binary]) of
        {ok, TtyOut} ->
            %% Raw fds are process-local: reader opens its own handle.
            Reader = spawn(fun() ->
                case file:open(TtyPath, [read, raw, binary]) of
                    {ok, TtyIn} ->
                        tty_to_port(TtyIn, Port);
                    {error, _} ->
                        ok
                end
            end),
            put(gleshell_output_shown, true),
            try
                collect_output_relay(Port, TtyOut, <<>>)
            after
                exit(Reader, kill),
                catch file:close(TtyOut)
            end;
        {error, _} ->
            %% Could not open the TTY for relay; still better than no PTY.
            put(gleshell_output_shown, false),
            collect_output(Port, <<>>)
    end.

tty_to_port(Tty, Port) ->
    case file:read(Tty, 256) of
        {ok, Data} when is_binary(Data), Data =/= <<>> ->
            catch port_command(Port, Data),
            tty_to_port(Tty, Port);
        {ok, _} ->
            tty_to_port(Tty, Port);
        eof ->
            ok;
        {error, _} ->
            ok
    end.

collect_output(Port, Acc) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            collect_output(Port, <<Acc/binary, Data/binary>>);
        {Port, {data, Data}} when is_list(Data) ->
            Bin = unicode:characters_to_binary(Data),
            collect_output(Port, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc}}
    after 120_000 ->
        catch port_close(Port),
        {error, <<"command timed out after 120s">>}
    end.

collect_output_relay(Port, Tty, Acc) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            _ = file:write(Tty, Data),
            collect_output_relay(Port, Tty, <<Acc/binary, Data/binary>>);
        {Port, {data, Data}} when is_list(Data) ->
            Bin = unicode:characters_to_binary(Data),
            _ = file:write(Tty, Bin),
            collect_output_relay(Port, Tty, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, Status}} ->
            {ok, {Status, normalize_pty_output(Acc)}}
    after 120_000 ->
        catch port_close(Port),
        {error, <<"command timed out after 120s">>}
    end.

%% PTY line discipline often emits CR-LF; normalize to LF for structured use.
normalize_pty_output(Bin) when is_binary(Bin) ->
    binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]).

%% True when the last external command already streamed output to the TTY
%% (PTY relay). Cleared after being read so the REPL does not double-print.
-spec take_output_shown() -> boolean().
take_output_shown() ->
    case erase(gleshell_output_shown) of
        true -> true;
        _ -> false
    end.

-spec clear_output_shown() -> nil.
clear_output_shown() ->
    erase(gleshell_output_shown),
    nil.

%% Find a terminal device attached to this BEAM (or an ancestor).
%% Note: os:getpid() returns a string, not an integer.
find_tty_path() ->
    case catch list_to_integer(os:getpid()) of
        Pid when is_integer(Pid) ->
            case tty_path_for_pid(Pid) of
                {ok, _} = Ok ->
                    Ok;
                error ->
                    walk_parent_tty(Pid, 12)
            end;
        _ ->
            error
    end.

walk_parent_tty(_Pid, 0) ->
    error;
walk_parent_tty(Pid, N) when is_integer(Pid), Pid > 1 ->
    case parent_pid(Pid) of
        {ok, Parent} when Parent > 1, Parent =/= Pid ->
            case tty_path_for_pid(Parent) of
                {ok, _} = Ok ->
                    Ok;
                error ->
                    walk_parent_tty(Parent, N - 1)
            end;
        _ ->
            error
    end;
walk_parent_tty(_, _) ->
    error.

tty_path_for_pid(Pid) when is_integer(Pid) ->
    case read_tty_nr(Pid) of
        {ok, 0} ->
            error;
        {ok, TtyNr} ->
            tty_nr_to_path(TtyNr);
        error ->
            error
    end.

read_tty_nr(Pid) when is_integer(Pid) ->
    case file:read_file("/proc/" ++ integer_to_list(Pid) ++ "/stat") of
        {ok, Bin} ->
            case parse_stat_tty_nr(binary_to_list(Bin)) of
                {ok, N} -> {ok, N};
                error -> error
            end;
        _ ->
            error
    end.
%% /proc/pid/stat: "pid (comm) state ppid pgrp session tty_nr ..."
parse_stat_tty_nr(List) ->
    case lists:splitwith(fun(C) -> C =/= $) end, List) of
        {_, [$) | Rest0]} ->
            Rest = string:trim(Rest0, leading),
            Fields = string:tokens(Rest, " "),
            %% After ')': state, ppid, pgrp, session, tty_nr → index 5
            case length(Fields) >= 5 of
                true ->
                    try
                        {ok, list_to_integer(lists:nth(5, Fields))}
                    catch
                        _:_ -> error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    end.

parent_pid(Pid) ->
    case file:read_file("/proc/" ++ integer_to_list(Pid) ++ "/stat") of
        {ok, Bin} ->
            case parse_stat_ppid(binary_to_list(Bin)) of
                {ok, P} -> {ok, P};
                error -> error
            end;
        _ ->
            error
    end.

parse_stat_ppid(List) ->
    case lists:splitwith(fun(C) -> C =/= $) end, List) of
        {_, [$) | Rest0]} ->
            Rest = string:trim(Rest0, leading),
            Fields = string:tokens(Rest, " "),
            %% After ')': state, ppid → index 2
            case length(Fields) >= 2 of
                true ->
                    try
                        {ok, list_to_integer(lists:nth(2, Fields))}
                    catch
                        _:_ -> error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    end.

%% Decode Linux tty_nr (see drivers/tty/tty_io.c / procfs) to a device path.
tty_nr_to_path(0) ->
    error;
tty_nr_to_path(TtyNr) when is_integer(TtyNr) ->
    Major = (TtyNr bsr 8) band 16#ff,
    Minor = (TtyNr band 16#ff) bor (((TtyNr bsr 20) band 16#fff) bsl 8),
    Path =
        case Major of
            136 ->
                "/dev/pts/" ++ integer_to_list(Minor);
            4 when Minor >= 64 ->
                "/dev/ttyS" ++ integer_to_list(Minor - 64);
            4 ->
                "/dev/tty" ++ integer_to_list(Minor);
            _ ->
                undefined
        end,
    case Path of
        undefined ->
            error;
        _ ->
            case file:read_file_info(Path) of
                {ok, _} -> {ok, Path};
                _ -> error
            end
    end.

reason_to_bin(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
reason_to_bin(Reason) when is_binary(Reason) ->
    Reason;
reason_to_bin(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
