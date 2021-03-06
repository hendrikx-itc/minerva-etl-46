# -*- coding: utf-8 -*-
import operator
from contextlib import closing

from minerva.directory import DataSource
from minerva.directory.entityref import EntityDnRef
from minerva.storage.notification import NotificationStore, Record, \
    Attribute
from minerva.storage.datatype import deduce_data_types, \
    type_map as datatype_map

from minerva_csvimporter.columndescriptor import ColumnDescriptor
from minerva_csvimporter.storage.storage import Storage


class NotificationStorage(Storage):
    def __init__(self, data_source):
        self.data_source = data_source

    def __str__(self):
        return "notification()"

    def store(self, column_names, fields, raw_data_rows):
        def f(conn):
            with closing(conn.cursor()) as cursor:
                data_source = DataSource.from_name(self.data_source)(cursor)

                notification_store = NotificationStore.load(cursor, data_source)

                rows = list(raw_data_rows)

                if notification_store:
                    datatype_dict = {
                        attribute.name: attribute.data_type
                        for attribute in notification_store.attributes
                    }

                    def merge_datatypes():
                        for name in column_names:
                            configured_descriptor = fields.get(name)

                            notificationstore_type = datatype_dict[name]

                            if configured_descriptor:
                                if configured_descriptor.data_type.name != notificationstore_type:
                                    raise Exception(
                                        "Attribute({} {}) type of "
                                        "notificationstore does not match "
                                        "configured type: {}".format(
                                            name, notificationstore_type,
                                            configured_descriptor.data_type.name
                                        )
                                    )

                                yield configured_descriptor
                            else:
                                yield ColumnDescriptor(
                                    name,
                                    datatype_map[notificationstore_type],
                                    {}
                                )

                    column_descriptors = list(merge_datatypes())
                else:
                    deduced_datatype_names = deduce_data_types(
                        map(operator.itemgetter(2), rows)
                    )

                    def merge_datatypes():
                        for column_name, datatype_name in zip(column_names, deduced_datatype_names):
                            configured_descriptor = fields.get(column_name)

                            if configured_descriptor:
                                yield configured_descriptor
                            else:
                                yield ColumnDescriptor(
                                    column_name,
                                    datatype_map[datatype_name],
                                    {}
                                )

                    column_descriptors = list(merge_datatypes())

                    attributes = [
                        Attribute(name, column_descriptor.data_type.name, '')
                        for name, column_descriptor in zip(column_names, column_descriptors)
                    ]

                    notification_store = NotificationStore(
                        data_source, attributes
                    ).create(cursor)

                    conn.commit()

                parsers = [
                    column_descriptor.string_parser()
                    for column_descriptor in column_descriptors
                ]

                for dn, timestamp, values in rows:
                    record = Record(
                        EntityDnRef(dn), timestamp, column_names,
                        [parse(value) for parse, value in zip(parsers, values)]
                    )

                    notification_store.store_record(record)(cursor)

            conn.commit()

        return f