# rss.py <command...>: peak resident memory (KiB) and CPU times of one run.
import resource, subprocess, sys, time
start = time.monotonic()
subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
wall = time.monotonic() - start
u = resource.getrusage(resource.RUSAGE_CHILDREN)
print(f"maxrss_kib={u.ru_maxrss} user_s={u.ru_utime:.3f} sys_s={u.ru_stime:.3f} wall_s={wall:.3f}")
