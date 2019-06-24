# -*- coding: utf-8 -*-
"""Provides the JobCollector class."""
import os
import logging
import re

import pyinotify

from minerva_dispatcher.harvestjobsource import HarvestJobSource, JOB_TYPE
from minerva_dispatcher.error import ConfigError
from minerva_dispatcher.pika_publisher import Publisher

EVENT_MASK = (
    pyinotify.IN_MOVED_TO |
    pyinotify.IN_CLOSE_WRITE |
    pyinotify.IN_CREATE  # Needed for auto-watching created directories
)

TIMEOUT = 1.0


class JobCollector:
    """
    Collects jobs for specified job_sources.

    Each harvest jobsource points to a directory and the JobCollector monitors
    the filesystem for new files using inotify.
    """
    def __init__(self, job_sources, rabbitmq_config):
        self.job_sources = job_sources

        self.publisher = Publisher(
            rabbitmq_config['url'],
            rabbitmq_config['queue'],
            rabbitmq_config['routing_key'],
            logging.getLogger(rabbitmq_config['logger'])
        )
        self.notifier = setup_notifier(
            self.job_sources, self.publisher.publish_message
        )

    def start(self):
        """Start the job collection."""
        self.publisher.start()

    def stop(self):
        """Stop the job collection."""
        self.publisher.stop()

    def run(self):
        """Run the notifier thread indefinitely."""
        self.notifier.loop()


def get_job_sources(config):
    return [
        HarvestJobSource(
            d["name"],
            d["job_type"],
            d["config"]
        )
        for d in config['job_sources']
    ]


def setup_notifier(job_sources, enqueue):
    """Setup and return ThreadedNotifier watching the job sources."""
    watch_manager = pyinotify.WatchManager()

    for job_source in job_sources:
        try:
            watch_source(watch_manager, enqueue, job_source)
        except ConfigError as exc:
            logging.error(exc)

    return pyinotify.Notifier(watch_manager)


def watch_source(watch_manager, enqueue, job_source):
    """Add a watch for the job source to watch_manager and return None."""
    match_pattern = job_source.config["match_pattern"]

    try:
        regex = re.compile(match_pattern)
    except re.error as exc:
        raise ConfigError(
            "invalid match_expression '{}': {}".format(match_pattern, exc))

    uri = job_source.config["uri"]

    try:
        os.stat(uri)
    except OSError as exc:
        raise ConfigError("error watching directory {}: {}".format(uri, exc))

    name_matches = regex.match

    def event_matches(event):
        return not event.dir and name_matches(event.name)

    def handle_event(event):
        if event_matches(event):
            file_path = os.path.join(event.path, event.name)

            enqueue(
                job_source.create_job(file_path)
            )

    proc_fun = event_handler({
        "IN_CLOSE_WRITE": handle_event,
        "IN_MOVED_TO": handle_event
    })

    recursive = job_source.config["recursive"]

    watch_manager.add_watch(
        uri, EVENT_MASK, proc_fun=proc_fun, rec=recursive, auto_add=True)

    logging.info("watching {} with filter {}".format(uri, match_pattern))


def no_op(*args, **kwargs):
    pass


def event_handler(handler_map, default_handler=no_op):
    """Return a function that handles events based on their type."""
    def f(event):
        handler_map.get(event.maskname, default_handler)(event)

    return f
