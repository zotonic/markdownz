ERL ?= erl

# Download Rebar3 when it is not available in the project directory.
REBAR := ./rebar3
REBAR_URL := https://s3.amazonaws.com/rebar3/rebar3
REBAR_OPTS ?=

.PHONY: all upgrade-deps compile shell test xref dialyzer edoc check clean dist-clean

all: compile

$(REBAR):
	$(ERL) -noshell -s inets -s ssl \
	  -eval '{ok, saved_to_file} = httpc:request(get, {"$(REBAR_URL)", []}, [{ssl, [{verify, verify_none}]}], [{stream, "$(REBAR)"}])' \
	  -s init stop
	chmod +x $(REBAR)

upgrade-deps: $(REBAR)
	$(REBAR) $(REBAR_OPTS) upgrade

compile: $(REBAR)
	$(REBAR) $(REBAR_OPTS) compile

shell: $(REBAR) compile
	$(REBAR) $(REBAR_OPTS) shell

test: $(REBAR)
	$(REBAR) $(REBAR_OPTS) eunit

xref: $(REBAR)
	$(REBAR) $(REBAR_OPTS) xref

dialyzer: $(REBAR)
	$(REBAR) $(REBAR_OPTS) dialyzer

edoc: $(REBAR)
	$(REBAR) $(REBAR_OPTS) ex_doc

check: compile test xref dialyzer

clean: $(REBAR)
	$(REBAR) $(REBAR_OPTS) clean

dist-clean: clean
	$(REBAR) $(REBAR_OPTS) clean -a
	rm -f $(REBAR)

