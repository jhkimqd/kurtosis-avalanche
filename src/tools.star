"""Run journaled orchestration commands inside the tools service."""


def execute(plan, command, extract={}):
    return plan.exec(
        service_name="tools", recipe=ExecRecipe(command=command, extract=extract)
    )
