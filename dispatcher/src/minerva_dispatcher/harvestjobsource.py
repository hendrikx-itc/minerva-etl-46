# -*- coding: utf-8 -*-
"""Provides the JobSource class."""
__docformat__ = "restructuredtext en"
__copyright__ = """
Copyright (C) 2008-2013 Hendrikx-ITC B.V.

Distributed under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3, or (at your option) any later
version.  The full license is in the file COPYING, distributed as part of
this software.
"""
import os

from minerva.system.jobsource import JobSource
from minerva.system.job import Job

JOB_TYPE = "harvest"


class HarvestJobSource(JobSource):
    def job_description(self, dir_path):
        description = {"uri": dir_path}
        description.update(self.config["job_config"])
        return description

    def create_job(self, file_path):
        try:
            file_size = os.path.getsize(file_path)
        except OSError as exc:
            raise Exception("could not get size of file: {}".format(exc))

        return Job(
            id_=None,
            job_source_id=self.id,
            type_=JOB_TYPE,
            description=self.job_description(file_path),
            size=file_size
        )
