"""No-op verifier for the _warmup task: always passes."""


def verify_warmup(traj, env_info, task_info):
    return {
        "passed": True,
        "score": 1.0,
        "feedback": "warmup task — verifier always passes",
    }
