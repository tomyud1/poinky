import test_cart, traceback
failed = 0
for name in [n for n in dir(test_cart) if n.startswith("test_")]:
    try:
        getattr(test_cart, name)(); print("PASS", name)
    except AssertionError:
        failed += 1; print("FAIL", name); traceback.print_exc()
print(f"{failed} failed")
raise SystemExit(1 if failed else 0)
