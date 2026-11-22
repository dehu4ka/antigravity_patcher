PREFIX ?= $(HOME)/.local
LIBDIR := $(PREFIX)/lib/antigravity-region-fix
BINDIR := $(PREFIX)/bin

.PHONY: all test lint install uninstall status gates

all: test

test:
	python3 tests/test_patcher.py

lint:
	python3 -m py_compile agy_region_fix.py tests/test_patcher.py

install: lint
	install -d "$(DESTDIR)$(LIBDIR)" "$(DESTDIR)$(BINDIR)"
	install -m 644 agy_region_fix.py "$(DESTDIR)$(LIBDIR)/agy_region_fix.py"
	install -m 755 agy-region-fix "$(DESTDIR)$(BINDIR)/agy-region-fix"
	@echo "Установлено: $(BINDIR)/agy-region-fix"
	@echo "Проверка:    agy-region-fix status"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/agy-region-fix"
	rm -rf "$(DESTDIR)$(LIBDIR)"

status:
	./agy-region-fix status

gates:
	./agy-region-fix gates
