from utils.errors import error
from functools import wraps


def mutates(f):
    """Indicate that a view function mutates the database. An error
    will be returned to the user if the system is running in read-only
    mode.

    :param f: The view function
    """

    @wraps(f)
    def wrapper(request):
        if request.registry.settings['readonly']:
            return error(request, 'The database is read-only.')

        return f(request)

    return wrapper