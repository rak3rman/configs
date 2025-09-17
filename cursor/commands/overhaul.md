The current implementation is too complex and should be overhauled from
scratch.

Use first principles to question assumptions, strip the problem to its atomic
parts, then design and implement a cleaner solution. If this is code, prefer
deletion over abstraction and keep one clear contract per module with names that
explain intent. Remove duplication, inline trivial indirection, and make invalid
states unrepresentable.

Revisit the cursor/rules/system-prompt-local.mdc rule for additional guidance.