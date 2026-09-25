# A small shop's till, for the colour samples (041).
FLOAT ?= 150
SOURCES := $(wildcard src/*.c)
OBJECTS := $(SOURCES:.c=.o)

.PHONY: all clean

all: till

till: $(OBJECTS)
	$(CC) -o $@ $^ -DFLOAT=$(FLOAT)

%.o: %.c
	$(CC) -c $< -o $@

clean:
	rm -f till $(OBJECTS)
	@echo "cleaned"
