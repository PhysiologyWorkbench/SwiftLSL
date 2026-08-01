"""Mock LSL peers, written from SCOPE.md §2 alone.

These deliberately do not consult liblsl: they are the second, independent reference
the Swift implementation is triangulated against (TESTING.md, *Principle: triangulation*).
A mock that accepts a malformed message from us is a test bug.
"""
