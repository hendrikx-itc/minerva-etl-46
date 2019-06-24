# -*- coding: utf-8 -*-
"""
Unit tests for the core.datatype module
"""
from nose.tools import assert_raises, assert_true, assert_false, assert_equal

from minerva_dispatcher import Consumer


def test_dispatcher():
    dispatcher = Dispatcher(datasources=[], max_queue_size=10, harvester_conn_provider=None)

def test_register_datasource():
    datasources = []

    def do_nothing():
        pass

    def do_nothing():
        pass

    datasource = DataSource("test_source", "measurement", "/data/measurement_data")
    datasource.recursive = True
    datasource.on_success = do_nothing
    datasource.on_error = do_nothing
    datasources.append(datasource)

    dispatcher = Dispatcher(datasources=datasources, max_queue_size=10, harvester_conn_provider=None)
