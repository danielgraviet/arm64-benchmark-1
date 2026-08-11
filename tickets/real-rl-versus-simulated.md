- real rl will update our 3 layer neural net policy, by doing gradient descent. 
- real rl will apply a "max-subtraction" to make the softmax more stable.
- real rl would have a environment/world that may not change as much as our random numbers.
- real rl has a very complex reward function that uses things like PPO, DQN to be accurate. "reward engineering" is often the hard part. 

- rl simulation does a 3 layer neural net policy that does not update its weights. 
- rl simulation does not have an explore/exploit tradeoff, and is a greedy algorithm.
- our rl simulation is mainly reward signal so that the loop looks real, and return is deterministic for checksums. Our reward fx is a hand written formula on the next state and the action. 
