# -*- coding: utf-8 -*-
__docformat__ = "restructuredtext en"

__copyright__ = """
Copyright (C) 2008-2013 Hendrikx-ITC B.V.

Distributed under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3, or (at your option) any later
version.  The full license is in the file COPYING, distributed as part of
this software.
"""
import csv

from minerva.util import k


QUOTING_MAP = {
    "QUOTE_ALL": csv.QUOTE_ALL,
    "QUOTE_MINIMAL": csv.QUOTE_MINIMAL,
    "QUOTE_NONNUMERIC": csv.QUOTE_NONNUMERIC,
    "QUOTE_NONE": csv.QUOTE_NONE
}


def create_dialect(conf):
    if conf["type"] == "custom":
        return k(create_custom(conf["config"]))
    elif conf["type"] == "auto":
        return sniff_dialect
    elif conf["type"] == "prime":
        return k(Prime)
    else:
        raise Exception("Unsupported dialect type")


def create_custom(conf):
    return type(
        'CustomDialect',
        (object, csv.Dialect),
        dict(
            delimiter=conf.get('delimiter', ','),
            quotechar=conf.get('quotechar', '"'),
            quoting=QUOTING_MAP.get(conf.get('quoting'), csv.QUOTE_MINIMAL),
            lineterminator=conf.get('lineterminator', '\r\n'),
            doublequote=conf.get('doublequote', True)
        )
    )


def sniff_dialect(csv_file):
    sample = csv_file.read(128000)
    csv_file.seek(0)

    return csv.Sniffer().sniff(sample)


class Prime(csv.Dialect):
    quoting = csv.QUOTE_NONE
    delimiter = ";"
    lineterminator = "\n"