// 内置示例课表：学期开始当天为第 1 周（单周），覆盖单/双/每周三种 parity
import { createCourse } from './schedule.js';

export function demoCourses() {
  const mk = (o) => createCourse(o);
  return [
    mk({ name: '高等数学', teacher: '张老师', location: '教1-201', dayOfWeek: 1, startTime: '08:00', endTime: '09:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
    mk({ name: '大学英语', teacher: '李老师', location: '外语楼305', dayOfWeek: 1, startTime: '10:00', endTime: '11:40', startWeek: 1, endWeek: 16, weekParity: 'single' }),
    mk({ name: '体育', location: '操场', dayOfWeek: 2, startTime: '14:00', endTime: '15:40', startWeek: 1, endWeek: 16, weekParity: 'double' }),
    mk({ name: '信号与系统', teacher: '王老师', location: '教2-508', dayOfWeek: 3, startTime: '08:00', endTime: '09:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
    mk({ name: '数据结构', teacher: '陈老师', location: '实验楼B204', dayOfWeek: 3, startTime: '14:00', endTime: '15:40', startWeek: 1, endWeek: 16, weekParity: 'single' }),
    mk({ name: '马克思主义原理', location: '教3-101', dayOfWeek: 4, startTime: '10:00', endTime: '11:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
    mk({ name: 'Python 程序设计', teacher: '刘老师', location: '机房302', dayOfWeek: 5, startTime: '14:00', endTime: '15:40', startWeek: 1, endWeek: 16, weekParity: 'double' }),
  ];
}
