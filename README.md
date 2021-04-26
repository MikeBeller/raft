# raft

RAFT consensus protocol in Elixir.
Each subdirectory contains a working version of the project as
it progressively increases in complexity.

NOTE this is for pedagogical purposes and my own explorations
of RAFT and Elixir.  Not intended for production use!

## References

In working on this project I made use of / reference to the following:

[Raft site and paper](https://raft.github.io/)
[Erlang implementation of Raft](https://github.com/rabbitmq/ra)
[Elixir implementation of Raft](https://github.com/toniqsystems/raft)

## Raft1

This version is a purely functional library which implements
the consensus state machine computations themselves, without
any processes.  

I got the idea to try it this way from Sasa Juric's article:
[To Spawn or Not to Spawn](https://www.theerlangelist.com/article/spawn_or_not)


## Raft2

Will add a server process to the system, managing the state of
the pure functional library created in Raft1


