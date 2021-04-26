# raft

Explorations of the RAFT consensus protocol using Elixir.
Each subdirectory contains a working version of the project as
it progressively increases in complexity.

## Raft1

This version is a purely functional library which implements
the consensus state machine computations themselves, without
any processes.  

I got the idea to try it this way from Sasa Juric's article:
[To Spawn or Not to Spawn](https://www.theerlangelist.com/article/spawn_or_not)


## Raft2

Will add a server process to the system, managing the state of
the pure functional library created in Raft1


