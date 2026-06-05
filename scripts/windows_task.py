def build_task_command(
    script_path,
    config_path,
    task_name="AD Password Sentinel",
    schedule="DAILY",
    start_time="08:00",
):
    action = (
        "powershell.exe -NoProfile -ExecutionPolicy Bypass "
        f"-File \"{script_path}\" -ConfigPath \"{config_path}\""
    )
    return (
        f'schtasks /Create /TN "{task_name}" /SC {schedule} /ST {start_time} '
        f'/TR "{action}" /F'
    )
