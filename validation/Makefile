.PHONY: all compile test_go test_odin test

all: compile test

compile:
	rm -fr ./out;
	mkdir -p ./out/odin;
	mkdir -p ./out/go;
	protoc --proto_path=./pb \
		--go_out=paths=source_relative:./out/go \
		--odin_out=./out/odin \
		./pb/*.proto;

test_go: compile
	go mod tidy
	go run go_writer.go
	odin test odin_reader_test.odin -file
	rm payload.bin

test_odin: compile
	odin run odin_writer.odin -file
	go test -v
	rm payload_odin.bin

test: test_go test_odin
