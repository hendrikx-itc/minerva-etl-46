# -*- coding: utf-8 -*-
from datetime import datetime
import logging
from contextlib import closing

import pytz
import psycopg2
from dateutil import parser as datetime_parser

from minerva.storage import get_plugin

from minerva_node.error import JobError, JobDescriptionError, JobExecutionError
from minerva_materialize.types import Materialization


class MaterializeJob(object):
    def __init__(self, conn, id, description):
        self.conn = conn
        self.id = id
        self.description = description

        try:
            self.type_id = self.description["type_id"]
        except KeyError:
            raise JobDescriptionError("'type_id' not set in description")

        try:
            timestamp_str = self.description["timestamp"]
        except KeyError:
            raise JobDescriptionError("'timestamp' not set in description")

        self.timestamp = datetime_parser.parse(timestamp_str)

    def __str__(self):
        return "materialization {} for timestamp {}".format(
                self.type_id, self.timestamp)

    def execute(self):
        load = Materialization.load_by_id(self.type_id)

        with closing(self.conn.cursor()) as cursor:
            materialization = load(cursor)

            chunk = materialization.chunk(self.timestamp)

            processed_max_modified, row_count = chunk.execute(cursor)

        msg_template = "'{0}'(id: {1}) materialized {2} records up to {3} for timestamp {4}"

        logging.info(msg_template.format(materialization,
                materialization.id, row_count, processed_max_modified,
                self.timestamp.isoformat()))

        self.conn.commit()
