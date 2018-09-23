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

## Development targets.

partisan:
	rm -rf _build/test/logs; clear; pkill beam.smp; $(REBAR) ct --suite=hbbft_distributed_SUITE --case=simple_test --readable=false -v

partisan-logs:
	find _build/test/logs -name "console.log" | xargs cat

partisan-clone:
	git clone http://github.com/lasp-lang/partisan.git _checkouts/partisan

dos2unix:
	find . -type f | xargs dos2unix