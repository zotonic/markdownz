%% @doc Behaviour for Markdown parser plugins.
-module(markdownz_plugin).

-callback init(Config :: markdownz:config(), Options :: map()) -> markdownz:config().
