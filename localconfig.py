# This file customizes the CloudLab cluster configuration. It is automatically
# included by config.py.
hosts = []
for i in range(1, 20):
    hosts.append(('rc%02d' % i, '10.10.1.%d' % (1 + i), i))

