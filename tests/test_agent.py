from agent import OpenShiftAgent


def test_status_contains_agent_name() -> None:
    agent = OpenShiftAgent()
    status = agent.status()
    assert status["agent"] == "openshift-install-agent"


def test_environment_shape_is_consistent() -> None:
    agent = OpenShiftAgent()
    environment = agent.validate_environment()
    assert "ok" in environment
    assert "message" in environment
    assert "missing" in environment
