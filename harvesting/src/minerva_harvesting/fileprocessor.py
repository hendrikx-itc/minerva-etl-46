#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Provides the function process_file for processing a single file.
"""
import os
import threading
import time
import traceback
from operator import not_

from minerva.util import compose

from minerva_harvesting.error import DataError


class ParseError(Exception):
    pass


def process_file(
        file_path, parser, handle_package, show_progress=False):
    """
    Process a single file with specified plugin.
    """
    if not os.path.exists(file_path):
        raise Exception("Could not find file '{0}'".format(file_path))

    _directory, filename = os.path.split(file_path)

    with open(file_path) as data_file:
        stop_event = threading.Event()
        condition = compose(not_, stop_event.is_set)

        if show_progress:
            start_progress_reporter(data_file, condition)

        try:
            for package in parser.packages(data_file, filename):
                handle_package(package)
        except DataError as exc:
            raise ParseError("{0!s} at position {1:d}".format(
                exc, data_file.tell()))
        except Exception:
            stack_trace = traceback.format_exc()
            position = data_file.tell()
            message = "{0} at position {1:d}".format(stack_trace, position)
            raise Exception(message)
        finally:
            stop_event.set()


def start_progress_reporter(data_file, condition):
    """
    Start a daemon thread that reports about the progress (position in
    data_file).
    """
    data_file.seek(0, 2)
    size = data_file.tell()
    data_file.seek(0, 0)

    def progress_reporter():
        """
        Show progress in the file on the console using a progress bar.
        """
        while condition():
            position = data_file.tell()

            percentage = position / size * 100

            print('{}'.format(percentage))

            time.sleep(1.0)

    thread = threading.Thread(target=progress_reporter)
    thread.daemon = True
    thread.start()
    return thread
