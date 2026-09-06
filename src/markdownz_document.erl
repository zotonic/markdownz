%% Copyright 2026 Marc Worrell
%% SPDX-License-Identifier: MIT
%% @doc Markdown document envelope handling.
-module(markdownz_document).

-export([split/1]).

-define(MAX_FRONT_MATTER_BYTES, 16 * 1024).

-spec split(binary()) ->
    {ok, markdownz:document(binary())}
    | {error, invalid_front_matter, map()}.
split(<<16#EF, 16#BB, 16#BF, Rest/binary>>) ->
    split(Rest);
split(<<"---\n", Rest/binary>>) ->
    take_yaml_front_matter(Rest, 0, []);
split(<<"---\r\n", Rest/binary>>) ->
    take_yaml_front_matter(Rest, 0, []);
split(Content) ->
    {ok, #{front_matter => undefined, content => Content}}.

take_yaml_front_matter(_Content, Size, _Acc) when Size > ?MAX_FRONT_MATTER_BYTES ->
    {error, invalid_front_matter, #{
        reason => too_large,
        maximum => ?MAX_FRONT_MATTER_BYTES,
        size => Size
    }};
take_yaml_front_matter(Content, Size, Acc) ->
    case next_line(Content) of
        {line, Line, Rest} ->
            case strip_cr(Line) of
                <<"---">> ->
                    Source = join_lines(lists:reverse(Acc)),
                    {ok, #{
                        front_matter => #{format => yaml, source => Source},
                        content => Rest
                    }};
                _ ->
                    take_yaml_front_matter(
                        Rest,
                        Size + byte_size(Line) + 1,
                        [strip_cr(Line) | Acc])
            end;
        {last, <<"---">>} ->
            Source = join_lines(lists:reverse(Acc)),
            {ok, #{
                front_matter => #{format => yaml, source => Source},
                content => <<>>
            }};
        {last, _Line} ->
            {error, invalid_front_matter, #{reason => missing_closing_delimiter}}
    end.

next_line(Content) ->
    case binary:match(Content, <<"\n">>) of
        {Position, 1} ->
            <<Line:Position/binary, _Newline, Rest/binary>> = Content,
            {line, Line, Rest};
        nomatch ->
            {last, strip_cr(Content)}
    end.

strip_cr(Line) when byte_size(Line) > 0 ->
    PrefixSize = byte_size(Line) - 1,
    case Line of
        <<Prefix:PrefixSize/binary, "\r">> -> Prefix;
        _ -> Line
    end;
strip_cr(Line) ->
    Line.

join_lines([]) -> <<>>;
join_lines(Lines) -> iolist_to_binary(lists:join($\n, Lines)).
