build:
	clear
	gcc -g -Wall -std=c99 smallsh.c -o smallsh

run:
	./smallsh

clean:
	rm -f smallsh

test:
	./smallsh

