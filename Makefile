.PHONY: compile rel test typecheck

REBAR=./rebar3

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

cover:
	$(REBAR) cover

test: compile
	$(REBAR) as test do eunit,ct

typecheck:
	$(REBAR) dialyzer

partisan:
	clear; pkill beam.smp; $(REBAR) ct --suite=hbbft_distributed_SUITE --readable=false -v