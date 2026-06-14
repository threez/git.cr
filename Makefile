.PHONY: spec fmt fmtcheck lint integration docs build

all: fmtcheck lint spec

fmt:
	crystal tool format

fmtcheck:
	crystal tool format --check --check

spec:
	crystal spec -v

integration:
	crystal spec --tag integration -v

AMEBA=./lib/ameba/bin/ameba

$(AMEBA): $(AMEBA).cr
	crystal build -o $@ $(AMEBA).cr

build:
	shards build --release

docs:
	crystal docs --output docs/

lint: $(AMEBA)
	$(AMEBA)
