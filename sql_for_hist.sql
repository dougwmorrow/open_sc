-- View recent job history for a specific job
SELECT 
    j.name AS JobName,
    h.step_name,
    h.run_date,
    h.run_time,
    h.run_duration,
    CASE h.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In Progress'
    END AS RunStatus,
    h.message
FROM msdb.dbo.sysjobhistory h
INNER JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
WHERE j.name = 'YourJobName'  -- Replace with your job name
ORDER BY h.run_date DESC, h.run_time DESC

-- View job history for all jobs
SELECT 
    j.name AS JobName,
    h.run_date,
    h.run_time,
    h.run_duration,
    CASE h.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In Progress'
    END AS RunStatus
FROM msdb.dbo.sysjobhistory h
INNER JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
WHERE h.step_id = 0  -- 0 represents the overall job outcome
ORDER BY h.run_date DESC, h.run_time DESC
