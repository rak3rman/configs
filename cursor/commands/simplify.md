The current implementation is too complex and should be simplified without
changing behavior or meaningful loss of context.

Use first principles to strip the problem to its essentials. If this is code,
prefer deletion over abstraction and keep one clear contract per module with
names that explain intent. Remove duplication, inline trivial indirection, and
make invalid states unrepresentable; no new features; tests stay green;
performance must not regress.

This isn't a scorched earth exercise either, don't completely throw away the
existing implementation unless you believe it is of medium or low quality.