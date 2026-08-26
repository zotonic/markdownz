%% @doc URL normalization compatible with markdown-it link handling.
-module(markdownz_url).

-export([normalize/1, normalize_text/1]).

-spec normalize(binary()) -> binary().
normalize(Url) ->
    encode_uri(recode_hostname(Url, ascii)).

-spec normalize_text(binary()) -> binary().
normalize_text(Url) ->
    decode_uri(recode_hostname(Url, unicode)).

recode_hostname(<<"//", Rest/binary>>, Mode) ->
    {Authority, Tail} = take_authority(Rest),
    <<"//", (recode_authority(Authority, Mode))/binary, Tail/binary>>;
recode_hostname(Url, Mode) ->
    case binary:match(Url, <<":">>) of
        {Position, 1} ->
            Scheme = binary:part(Url, 0, Position),
            AfterPosition = Position + 1,
            AfterScheme = binary:part(Url, AfterPosition,
                byte_size(Url) - AfterPosition),
            recode_scheme(lower_ascii(Scheme), Scheme, AfterScheme, Mode);
        nomatch ->
            Url
    end.

recode_scheme(Scheme, OriginalScheme, <<"//", Rest/binary>>, Mode)
        when Scheme =:= <<"http">>; Scheme =:= <<"https">> ->
    {Authority, Tail} = take_authority(Rest),
    <<OriginalScheme/binary, "://",
        (recode_authority(Authority, Mode))/binary, Tail/binary>>;
recode_scheme(<<"mailto">>, OriginalScheme, Address, Mode) ->
    <<OriginalScheme/binary, $:, (recode_email(Address, Mode))/binary>>;
recode_scheme(_Scheme, OriginalScheme, AfterScheme, _Mode) ->
    <<OriginalScheme/binary, $:, AfterScheme/binary>>.

take_authority(Bin) ->
    take_authority(Bin, 0).

take_authority(<<>>, _Position) ->
    {<<>>, <<>>};
take_authority(Bin, Position) when Position >= byte_size(Bin) ->
    {Bin, <<>>};
take_authority(Bin, Position) ->
    case binary:at(Bin, Position) of
        Separator when Separator =:= $/; Separator =:= $?; Separator =:= $# ->
            split_at(Bin, Position);
        _ ->
            take_authority(Bin, Position + 1)
    end.

recode_authority(Authority, Mode) ->
    case split_last(Authority, $@) of
        {UserInfo, HostPort} ->
            <<UserInfo/binary, $@, (recode_host_port(HostPort, Mode))/binary>>;
        none ->
            recode_host_port(Authority, Mode)
    end.

recode_host_port(<<$[, _/binary>> = HostPort, _Mode) ->
    HostPort;
recode_host_port(HostPort, Mode) ->
    case split_last(HostPort, $:) of
        {Host, Port} ->
            <<(recode_host(Host, Mode))/binary, $:, Port/binary>>;
        none ->
            recode_host(HostPort, Mode)
    end.

recode_email(Address0, Mode) ->
    {Address, Tail} = split_email_tail(Address0),
    case split_last(Address, $@) of
        {Local, Host} ->
            <<Local/binary, $@, (recode_host(Host, Mode))/binary, Tail/binary>>;
        none ->
            Address0
    end.

split_email_tail(Address) ->
    case first_separator(Address, [$?, $#]) of
        none -> {Address, <<>>};
        Position -> split_at(Address, Position)
    end.

recode_host(<<>>, _Mode) ->
    <<>>;
recode_host(Host0, Mode) ->
    Host = normalize_domain_separators(Host0),
    Labels = binary:split(Host, <<".">>, [global]),
    iolist_to_binary(lists:join(<<".">>, [recode_label(Label, Mode) || Label <- Labels])).

normalize_domain_separators(Host) ->
    lists:foldl(
        fun(Separator, Acc) ->
            binary:replace(Acc, Separator, <<".">>, [global])
        end,
        Host,
        [<<16#3002/utf8>>, <<16#ff0e/utf8>>, <<16#ff61/utf8>>]).

recode_label(Label, ascii) ->
    case is_ascii(Label) of
        true -> Label;
        false ->
            case markdownz_punycode:encode(Label) of
                {ok, Encoded} -> <<"xn--", Encoded/binary>>;
                error -> Label
            end
    end;
recode_label(<<Prefix:4/binary, Encoded/binary>> = Label, unicode) ->
    case lower_ascii(Prefix) of
        <<"xn--">> ->
            case markdownz_punycode:decode(Encoded) of
                {ok, Decoded} -> Decoded;
                error -> Label
            end;
        _ -> Label
    end;
recode_label(Label, unicode) ->
    Label.

encode_uri(Bin) ->
    iolist_to_binary([encode_uri_byte(Byte) || <<Byte>> <= Bin]).

encode_uri_byte(Byte) when Byte >= 33, Byte =< 126,
        Byte =/= 34, Byte =/= 60, Byte =/= 62, Byte =/= 92,
        Byte =/= 91, Byte =/= 93, Byte =/= 94, Byte =/= 96,
        Byte =/= 123, Byte =/= 124, Byte =/= 125 ->
    <<Byte>>;
encode_uri_byte(Byte) ->
    <<$%, (hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>>.

decode_uri(Bin) ->
    decode_uri(Bin, []).

decode_uri(<<$%, High, Low, Rest/binary>>, Acc) ->
    case {hex_value(High), hex_value(Low)} of
        {HighValue, LowValue} when is_integer(HighValue), is_integer(LowValue) ->
            Byte = HighValue bsl 4 bor LowValue,
            case decode_excluded(Byte) of
                true -> decode_uri(Rest, [<<$%, High, Low>> | Acc]);
                false -> decode_uri(Rest, [<<Byte>> | Acc])
            end;
        _ ->
            decode_uri(<<High, Low, Rest/binary>>, [<<$%>> | Acc])
    end;
decode_uri(<<Byte, Rest/binary>>, Acc) ->
    decode_uri(Rest, [<<Byte>> | Acc]);
decode_uri(<<>>, Acc) ->
    iolist_to_binary(lists:reverse(Acc)).

decode_excluded(Byte) ->
    lists:member(Byte, ";/?:@&=+$,#%").

split_last(Bin, Byte) ->
    case binary:matches(Bin, <<Byte>>) of
        [] -> none;
        Matches ->
            {Position, 1} = lists:last(Matches),
            After = Position + 1,
            {binary:part(Bin, 0, Position),
                binary:part(Bin, After, byte_size(Bin) - After)}
    end.

split_at(Bin, Position) ->
    {binary:part(Bin, 0, Position),
        binary:part(Bin, Position, byte_size(Bin) - Position)}.

first_separator(Bin, Separators) ->
    Positions = [Position
        || Separator <- Separators,
           {Position, 1} <- binary:matches(Bin, <<Separator>>)],
    case Positions of
        [] -> none;
        _ -> lists:min(Positions)
    end.

is_ascii(Bin) ->
    lists:all(fun(Byte) -> Byte < 128 end, binary_to_list(Bin)).

lower_ascii(Bin) ->
    << <<(lower_ascii_byte(Byte))>> || <<Byte>> <= Bin >>.

lower_ascii_byte(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
lower_ascii_byte(Byte) -> Byte.

hex_digit(Nibble) when Nibble < 10 -> $0 + Nibble;
hex_digit(Nibble) -> $A + Nibble - 10.

hex_value(Char) when Char >= $0, Char =< $9 -> Char - $0;
hex_value(Char) when Char >= $A, Char =< $F -> Char - $A + 10;
hex_value(Char) when Char >= $a, Char =< $f -> Char - $a + 10;
hex_value(_) -> error.
